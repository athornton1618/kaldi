#!/usr/bin/env bash
# Copyright      2018   David Snyder
#                2018   Johns Hopkins University (Author: Daniel Garcia-Romero)
#                2018   Johns Hopkins University (Author: Daniel Povey)
# Apache 2.0.

# This script trains the x-vector DNN.  The recipe is similar to the one
# described in "Diarization is Hard: Some Experiences and Lessons Learned
# for the JHU Team in the Inaugural DIHARD Challenge" by Sell et al.

. ./cmd.sh
set -e

stage=1
train_stage=-1
use_gpu=true
remove_egs=false

data=data/train
nnet_dir=exp/xvector_nnet_1a/
egs_dir=exp/xvector_nnet_1a/egs

. ./path.sh
. ./cmd.sh
. ./utils/parse_options.sh

num_pdfs=$(awk '{print $2}' $data/utt2spk | sort | uniq -c | wc -l)

# Now we create the nnet examples using sid/nnet3/xvector/get_egs.sh.
# The argument --num-repeats is related to the number of times a speaker
# repeats per archive.  If it seems like you're getting too many archives
# (e.g., more than 200) try increasing the --frames-per-iter option.  The
# arguments --min-frames-per-chunk and --max-frames-per-chunk specify the
# minimum and maximum length (in terms of number of frames) of the features
# in the examples.
#
# To make sense of the egs script, it may be necessary to put an "exit 1"
# command immediately after stage 3.  Then, inspect
# exp/<your-dir>/egs/temp/ranges.* . The ranges files specify the examples that
# will be created, and which archives they will be stored in.  Each line of
# ranges.* has the following form:
#    <utt-id> <local-ark-indx> <global-ark-indx> <start-frame> <end-frame> <spk-id>
# For example:
#    100304-f-sre2006-kacg-A 1 2 4079 881 23

# If you're satisfied with the number of archives (e.g., 50-150 archives is
# reasonable) and with the number of examples per speaker (e.g., 1000-5000
# is reasonable) then you can let the script continue to the later stages.
# Otherwise, try increasing or decreasing the --num-repeats option.  You might
# need to fiddle with --frames-per-iter.  Increasing this value decreases the
# the number of archives and increases the number of examples per archive.
# Decreasing this value increases the number of archives, while decreasing the
# number of examples per archive.
if [ $stage -le 6 ]; then
  echo "$0: Getting neural network training egs";
  # dump egs.
  # frame per iter original 1000000000
  # frame per iter diagnostic original 500000
  # num repeat original 1
  sid/nnet3/xvector/get_egs.sh --cmd "$train_cmd" \
    --nj 8 \
    --stage 0 \
    --frames-per-iter 100000 \
    --frames-per-iter-diagnostic 10000 \
    --min-frames-per-chunk 200 \
    --max-frames-per-chunk 400 \
    --num-diagnostic-archives 3 \
    --num-repeats 10 \
    "$data" $egs_dir
fi

if [ $stage -le 7 ]; then
  echo "$0: creating neural net configs using the xconfig parser";
  num_targets=$(wc -w $egs_dir/pdf2num | awk '{print $1}')
  feat_dim=$(cat $egs_dir/info/feat_dim)

  # This chunk-size corresponds to the maximum number of frames the
  # stats layer is able to pool over.  In this script, it corresponds
  # to 4 seconds.  If the input recording is greater than 4 seconds,
  # we will compute multiple xvectors from the same recording and average
  # to produce the final xvector.
  max_chunk_size=400

  # The smallest number of frames we're comfortable computing an xvector from.
  # Note that the hard minimum is given by the left and right context of the
  # frame-level layers.
  min_chunk_size=20
  mkdir -p $nnet_dir/configs
  cat <<EOF > $nnet_dir/configs/network.xconfig
  # please note that it is important to have input layer with the name=input

  # The frame-level layers
  input dim=${feat_dim} name=input
  relu-batchnorm-layer name=tdnn1 input=Append(-2,-1,0,1,2) dim=512
  relu-batchnorm-layer name=tdnn2 input=Append(-2,0,2) dim=512
  relu-batchnorm-layer name=tdnn3 input=Append(-3,0,3) dim=512
  relu-batchnorm-layer name=tdnn4 dim=512
  relu-batchnorm-layer name=tdnn5 dim=1500

  # The stats pooling layer. Layers after this are segment-level.
  # In the config below, the first and last argument (0, and ${max_chunk_size})
  # means that we pool over an input segment starting at frame 0
  # and ending at frame ${max_chunk_size} or earlier.  The other arguments (1:1)
  # mean that no subsampling is performed.
  stats-layer name=stats config=mean+stddev(0:1:1:${max_chunk_size})

  # This is where we usually extract the embedding (aka xvector) from.
  relu-batchnorm-layer name=tdnn6 dim=128 input=stats
  output-layer name=output include-log-softmax=true dim=${num_targets}
EOF

  steps/nnet3/xconfig_to_configs.py \
      --xconfig-file $nnet_dir/configs/network.xconfig \
      --config-dir $nnet_dir/configs/
  cp $nnet_dir/configs/final.config $nnet_dir/nnet.config

  # These three files will be used by sid/nnet3/xvector/extract_xvectors.sh
  echo "output-node name=output input=tdnn6.affine" > $nnet_dir/extract.config
  echo "$max_chunk_size" > $nnet_dir/max_chunk_size
  echo "$min_chunk_size" > $nnet_dir/min_chunk_size
fi

dropout_schedule='0,0@0.20,0.1@0.50,0'
srand=123
if [ $stage -le 8 ]; then
  steps/nnet3/train_raw_dnn.py --stage=$train_stage \
    --cmd="$train_cmd" \
    --trainer.optimization.proportional-shrink 10 \
    --trainer.optimization.momentum=0.5 \
    --trainer.optimization.num-jobs-initial=3 \
    --trainer.optimization.num-jobs-final=8 \
    --trainer.optimization.initial-effective-lrate=0.001 \
    --trainer.optimization.final-effective-lrate=0.0001 \
    --trainer.optimization.minibatch-size=64 \
    --trainer.srand=$srand \
    --trainer.max-param-change=2 \
    --trainer.num-epochs=3 \
    --trainer.dropout-schedule="$dropout_schedule" \
    --trainer.shuffle-buffer-size=1000 \
    --egs.frames-per-eg=1 \
    --egs.dir="$egs_dir" \
    --cleanup.remove-egs $remove_egs \
    --cleanup.preserve-model-interval=10 \
    --use-gpu=true \
    --dir=$nnet_dir  || exit 1;
fi

exit 0;
