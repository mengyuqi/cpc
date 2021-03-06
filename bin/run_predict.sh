#!/bin/bash

######################################################################
# 
# Constants: for the directory settings
# 

MYOWN_LOC=`dirname $0`;		# XXX: some hacking:)
DATA_DIR="$MYOWN_LOC/../data"
LIB_DIR="$MYOWN_LOC/../libs"

m_blast_db=$DATA_DIR/prot_db
m_framefinder_model=$DATA_DIR/framefinder.model
m_libsvm_model0=$DATA_DIR/libsvm.model0 # standard
m_libsvm_model=$DATA_DIR/libsvm.model # Prob
m_libsvm_model2=$DATA_DIR/libsvm.model2	# Prob + weighted version
m_libsvm_range=$DATA_DIR/libsvm.range

c_extract_blast_feat="$MYOWN_LOC/extract_blastx_features.pl"
c_extract_ff_feat="$MYOWN_LOC/extract_framefinder_feats.pl"
c_add_missing_entries="$MYOWN_LOC/add_missing_entries.pl"
c_feat2libsvm="$MYOWN_LOC/feat2libsvm.pl"
c_lsv_cbind="$MYOWN_LOC/lsv_cbind.pl"
c_join_columns="$MYOWN_LOC/join_columns.pl"
c_predict="$MYOWN_LOC/predict.pl"
c_generate_plot_feats="$MYOWN_LOC/generate_plot_features.pl"
c_split_plot_feats="$MYOWN_LOC/split_plot_features_by_type.pl"
c_index_blast_report="$MYOWN_LOC/make_blast_report_index.pl"

# 
# Constants: for the remote blast
# 
REMOTE_BLAST_HOST="162.105.250.200" # New LangChao
REMOTE_BLAST_MIN_SIZE=4000	# 4k
c_blast_smp_client="$MYOWN_LOC/server/client.pl"

#
# default arguments set
#
arg_working_dir='$tmp'
arg_evidence_files=""
arg_temp="FALSE"
arg_num_threads=1


######################################################################
# 
# Arguments
# 



function printhelp {
echo "Usage: run_predict.sh  [option]  input_seq output_file
-w/--work-dir          path to working directory, (i.e. the original third parameter)
                       default = create a working directory \$tmp
-k/--keep-tmp          keep working directory after exit, default = FALSE
-e/--evidence-files    prefix for evidence, (i.e. the original last parameter)
                       default = none (i.e. do not generate the evidence files)
-p/--num-threads       number of CPUs, default = 1
-d/--data_base         database used for blastx 
                       default = \$CPC_HOME/data/prot_db
-m/--model-file        Model file used for libsvm_predict
                       default = \$CPC_HOME/data/libsvm.model0
-h/--help              help
             ";
}

Arguments=`getopt -o w:ke:p:d:m:h -l work-dir:,keep-tmp,evidence-files:,num-threads:,data_base:,model-file:,help -n 'run_predict.sh' -- "$@"`


if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

eval set -- "$Arguments"


while true ; do
        case "$1" in
                -w|--work-dir) arg_working_dir=$2 ; shift 2 ;;
                -e|--evidence-files) arg_evidence_files=$2 ; shift 2 ;;
                -p|--num-threads) arg_num_threads=$2 ; shift 2 ;;
                -d|--data_base) m_blast_db=$2 ; shift 2 ;;
                -k|--keep-tmp) arg_temp="TRUE"; shift;;
                -m|--model-file) m_libsvm_model0=$2; shift 2;;
                -h|--help) printhelp ;exit 1 ;;    
                --) shift ; break ;;
                *) printhelp ; exit 1 ;;
        esac
done


if [ "$1" = "" ]; then echo "No input file"; printhelp ; exit 1; fi

if [ "$2" = "" ]; then echo "No output file" ;printhelp ;exit 1; fi

if [ "$3" != "" ]; then echo "format error" ;printhelp ;exit 1; fi

arg_input_seq=$1

arg_output_result=$2


############################################################
# 
# Step 0: detect necessary applications
# 
APP_BLAST=`which blastx 2> /dev/null`
test -x "$APP_BLAST" || (echo "Can't find blastx on your path, eheck it!" > /dev/stderr && exit 1)

APP_FF=`which framefinder 2> /dev/null`	# FF == FrameFinder
if test ! -x "$APP_FF"; then
    APP_FF=$LIB_DIR/framefinder;
    if test ! -x "$APP_FF"; then
	APP_FF=$LIB_DIR/estate/bin/framefinder;
	if test ! -x "$APP_FF"; then
	    echo "Can't find framefinder on your path or my own directory, quitting..." > /dev/stderr
	    exit 1
	fi;
    fi
fi

APP_SVM_SCALE="$LIB_DIR/libsvm/libsvm-2.81/svm-scale"
test -x "$APP_SVM_SCALE" || (echo "Can't find svm-scale on your path, eheck it!" > /dev/stderr && exit 1)

APP_SVM_PREDICT="$LIB_DIR/libsvm/libsvm-2.81/svm-predict"
APP_SVM_PREDICT2="$LIB_DIR/libsvm/libsvm-2.81/svm-predict2"
test -x "$APP_SVM_PREDICT" || (echo "Can't find svm-predict on your path, eheck it!" > /dev/stderr && exit 1)
test -x "$APP_SVM_PREDICT2" || (echo "Can't find svm-predict2 on your path, eheck it!" > /dev/stderr && exit 1)


# detect the BLAST database, failsafe
if test ! -f "${m_blast_db}.phr" -a ! -f "${m_blast_db}.00.phr"; then
    	echo "Can't find protein db under $DATA_DIR, pls check..." > /dev/stderr
	exit 1
fi

# detect working dir

test -d $arg_working_dir || (mkdir $arg_working_dir  || (echo "Can't make the working space ($arg_working_dir), quitting...." > /dev/stderr && exit 1))



# Step 1: run blastx & framefinder

# BLASTX settings: Combining the BLAST and Frith2006(PLoS & RNA) protocols
# XXX: the remote server will NOT use their own settings...
blast_opts="-strand plus";              # only the same strand
blast_opts="$blast_opts -evalue 1e-10"; # as a quick setting (BLASTX 2.2.26)
blast_opts="$blast_opts -ungapped";  # un-gapped blast (Frith2006, PLoS)
blast_opts="$blast_opts -threshold 14"; # Neighborhood word threshold score, default=12 (BLASTX 2.2.26)
blast_opts="$blast_opts -num_threads $arg_num_threads";  # 2 CPUs, boost the performance
blast_opts="$blast_opts -db $m_blast_db"	# database settings
blast_opts="$blast_opts -lcase_masking "
blast_opts="$blast_opts -outfmt 6";
blast_opts="$blast_opts -max_target_seqs 250";
blast_opts="$blast_opts -comp_based_stats F" #After BLASTX 2.2.27, this option is needed


# Framefinder settings
ff_opts="-r False -w $m_framefinder_model /dev/stdin"

# Entry the working space...
old_pwd=`pwd`

# Determine the right mode (local or remote) for running BLAST
input_seq_size=`stat -Lc "%s" $arg_input_seq`;

# local version
(cat $arg_input_seq | $APP_BLAST  $blast_opts | tee $arg_working_dir/blastx.table | perl $c_extract_blast_feat ) > $arg_working_dir/blastx.feat1 &

(cat $arg_input_seq | $APP_FF $ff_opts | tee $arg_working_dir/ff.fa1 | perl $c_extract_ff_feat ) > $arg_working_dir/ff.feat &

wait;

# a quick fix: adding possible missing entries due to blastx
cat $arg_input_seq | perl $c_add_missing_entries $arg_working_dir/blastx.feat1 > $arg_working_dir/blastx.feat
# Quick fix: remove redunancy \r in the ff.fa
cat $arg_working_dir/ff.fa1 | tr -d '\r' > $arg_working_dir/ff.fa

############################################################
# 
# Step 2: prepare data for libsvm
# 

# 1       2             3              4         5           6
# QueryID hit_seq_count hit_HSP_count  hit_score frame_score frame_score2

perl $c_feat2libsvm -c 2,4,6 NA NA $arg_working_dir/blastx.feat > $arg_working_dir/blastx.lsv &

# 1       2             3              4         5
# QueryID CDSLength     Score          Used     Strict
perl $c_feat2libsvm -c 2,3,4,5 NA NA $arg_working_dir/ff.feat > $arg_working_dir/ff.lsv &
wait;

perl -w $c_lsv_cbind $arg_working_dir/blastx.lsv $arg_working_dir/ff.lsv > $arg_working_dir/test.lsv
$APP_SVM_SCALE -r $m_libsvm_range $arg_working_dir/test.lsv > $arg_working_dir/test.lsv.scaled

############################################################
# 
# Step 3: do prediction
# 

$APP_SVM_PREDICT2 $arg_working_dir/test.lsv.scaled $m_libsvm_model0 $arg_working_dir/test.svm0.predict > $arg_working_dir/test.svm0.stdout 2> $arg_working_dir/test.svm0.stderr

cat $arg_working_dir/test.svm0.predict  | perl -w $c_predict $arg_input_seq > $arg_output_result

############################################################
# 
# Step 4: generate the output features for web-visualization
# 
if [ "$arg_evidence_files" != "" ];then
output_plot_feat_homo=${arg_evidence_files}.homo
output_plot_feat_orf=${arg_evidence_files}.orf

cat $arg_working_dir/blastx.feat | perl -w $c_generate_plot_feats $arg_working_dir/blastx.table $arg_working_dir/ff.fa | perl -w $c_split_plot_feats $output_plot_feat_homo $output_plot_feat_orf &

perl -w $c_index_blast_report $arg_working_dir/blastx.table > $arg_working_dir/blastx.index &

wait;
fi

############################################################
# 
# Step 5: make clean-up...
# 

rm -rf $arg_working_dir/blastx.feat1
rm -rf $arg_working_dir/ff.fa1

if [ "$arg_temp" != "TRUE" ];then
cd $arg_working_dir
rm -rf blastx.feat blastx.table blastx.lsv ff.fa ff.feat ff.lsv test.lsv test.lsv.scaled test.svm0.predict test.svm0.stderr test.svm0.stdout 
   if [ "$arg_evidence_files" != "" ];then
   rm -rf blastx.index
   fi

cd $old_pwd
rmdir $arg_working_dir

fi

cd $old_pwd