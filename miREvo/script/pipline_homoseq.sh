#!/bin/bash
shopt -s -o nounset

function USAGE {
	echo ""
	echo "Usage: miREvo homoseq -o prefix -i reads -H hairpin -M mature.fa -r reference.fasta -m in.maf [options]"
	echo "    Options for homolog searching"
	echo "        -o  <str>   abbreviation for project name, 3 letter code for the sequencing library or the species of interest, required"
	echo "        -i  <str>   sequence reads file in FASTA format, uniqe merged, required"
	echo "        -r  <str>   reference file, FASTA format, required"
	echo "        -m  <str>   The UCSC MAF file ( Multiple Alignment Format file), required"
	echo "        -H  <str>   Botwtie index for known miRNAs' hairpin sequences. These should be the known haripin sequences for the species being analyzed."
	echo "                    the miRNAs' ID must be in miRBase format, for example '>dme-miR-1'"
	echo "        -M  <str>   fasta file with miRNAs mature. These should be the known mature sequences for the species being analyzed."
	echo "                    the miRNAs' ID must be in miRBase format, for example '>dme-miR-1-5p'"
	echo "        -s  <str>   miRBase miRNA sequences in fasta format. These should be the pooled known mature sequences for 1-5 species"
	echo "                    closely related to the species being analyzed."
	echo "        -c  <str>   liftOver file (chain file), "
	echo "        -t  <int>   temperature cut-off for RNAfold when calculating secondary structures of RNAs, default=22"
	echo ""
	echo "    Options for Bowtie:"
	echo "        -p  <int>   number of processors to use, default=1"
}

if [ $# -eq 0 ]; then
	USAGE;
	exit 192;
fi

declare -rx SCRIPT=${0##*/}
declare -r OPTSTRING="r:i:o:M:H:s:m:c:t:p:h"
declare SWITCH
declare genome
declare maffile
declare chainfile=" "
declare reads
declare mature
declare other_mature 
declare hairpin 
declare prj
declare projname
declare -t TEMP=22
declare -i CPU=1


program_dir="$MIREVO/script"

while getopts "$OPTSTRING" SWITCH ; do
	case $SWITCH in
		h) USAGE
		   exit 0
		;;
		r) genome="$OPTARG"
		;;
		i) reads="$OPTARG"
		;;
		M) mature="$OPTARG"
		;;
		H) hairpin="$OPTARG"
		;;
		s) other_mature="$OPTARG"
		;;
		o) prj="$OPTARG"
		;;
		m) maffile="$OPTARG"
		;;
		c) chainfile="$OPTARG"
		;;
		t) TEMP="$OPTARG"
		;;
		p) CPU="$OPTARG"
		;;
		\?) exit 192
		;;
		*) printf "miREvo homoseq: $LINENO: %s\n" "script error: unhandled argument"
		exit 192
		;;
	esac
done

cmdlog=$prj/homoseq.cmd

if [ ! -e  $prj ]; then
	mkdir $prj
fi


projname=`basename $prj`
blatout=$prj/homoseq.cand.VS.genome.blat

declare hairpin_seq

if [[  -e $hairpin.fa  ]]; then
	hairpin_seq=$hairpin.fa
elif [[ -e $hairpin.fas  ]]; then
	hairpin_seq=$hairpin.fas
elif [[ -e $hairpin.fasta  ]]; then
	hairpin_seq=$hairpin.fasta
else
	echo "Can't locate the fasta sequence for $hairpin";
	echo "Please provide an avaliabe $hairpin sequence, such as";
	echo "$hairpin.fa, $hairpin.fas, $hairpin.fasta, etc."
	echo "and build the Bowtie index using a command like:"
	echo "bowtie-build -f $hairpin.fa $hairpin"
	echo "exit now."
	exit 192;
fi

other_mature_new=homoseq.`basename $other_mature`
echo "perl $program_dir/rna2dna.pl $other_mature > $prj/$other_mature_new" > $cmdlog
perl $program_dir/rna2dna.pl $other_mature > $prj/$other_mature_new

echo "perl $program_dir/combine_mirna_mature.pl $projname $mature $hairpin_seq $prj/$other_mature_new > $prj/homoseq.mirna.fas" >> $cmdlog
perl $program_dir/combine_mirna_mature.pl $projname $mature $hairpin_seq $prj/$other_mature_new > $prj/homoseq.mirna.fas

#mapping fasta sequence to genome by using blat
echo "blat $genome $prj/homoseq.map_hp.fas $blatout"  >> $cmdlog
blat $genome $prj/homoseq.mirna.fas $blatout

#extract perfect matching
echo "perl $program_dir/parse_perfect_match_from_blat.pl $blatout $blatout.match"  >> $cmdlog
perl $program_dir/parse_perfect_match_from_blat.pl $blatout $blatout.match 

#sorting
#msort -t '\t' -k 'f2,n4' $blatout.match > $blatout.match-sort
echo "sort -k2,2d -k4,4n $blatout.match > $blatout.match-sort" >> $cmdlog
sort -k2,2d -k4,4n $blatout.match > $blatout.match-sort

#combining overlaping results
echo "perl  $program_dir/combined_overlap.pl $blatout.match-sort $prj/homoseq.repinfo.txt > $prj/homoseq.cand.slim.txt" >> $cmdlog
perl  $program_dir/combined_overlap.pl $blatout.match-sort $prj/homoseq.repinfo.txt > $prj/homoseq.cand.slim.txt

gfffile="$prj/homoseq.cand.slim.gff"
bedfile="$prj/homoseq.cand.slim.bed"

#get candidate sequences and generating gff files
echo "perl $program_dir/get_flank_seq_simple.pl $prj/homoseq.cand.slim.txt $genome $gfffile $bedfile 10" >> $cmdlog
perl $program_dir/get_flank_seq_simple.pl $prj/homoseq.cand.slim.txt $genome $gfffile $bedfile 10 

aln_outdir=$prj"/homo_aln/"
if [ -e $aln_outdir ]; then
	rm -rf $aln_outdir
fi
#--------------------------------------------------
# if [ ! $chainfile = " " -a -f $chainfile ]; then
#-------------------------------------------------- 
if [[ -f $chainfile ]]; then
	echo "here"
	oldbed=$bedfile
	bedfile="$prj/homoseq.cand.slim.bed.lift"
	unmap=$oldbed.unmap
	liftOver $oldbed $chainfile $bedfile $unmap
	echo "liftOver $oldbed $chainfile $bedfile $unmap" >> $cmdlog
fi

echo "mafsInRegion -outDir $bedfile $aln_outdir $maffile" >> $cmdlog
mafsInRegion -outDir $bedfile $aln_outdir $maffile

log_file="$prj/homoseq.combine.maf.log"
if [ -e $log_file ]; then
	echo "rm -f $log_file" >> $cmdlog
	rm -f $log_file
fi

major_id=`grep '^s ' -A1 $maffile | head -1 | awk '{print $2}' | cut -f1 -d '.'`

echo "perl $program_dir/combined_maf_all.pl $aln_outdir $gfffile $major_id > $log_file" >> $cmdlog
perl $program_dir/combined_maf_all.pl $aln_outdir $gfffile $major_id > $log_file

#--------------------------------------------------
# while true ; do
# 	bed_maf_num=`wc -l $log_file | awk '{print $1}'`
# 	if [ $bed_maf_num -gt 0 ] ; then
# 		echo "R --slave --no-restore --no-save --no-readline $bedfile $log_file < $program_dir/ana_combined.R" >> $cmdlog
# 		R --slave --no-restore --no-save --no-readline $bedfile $log_file < $program_dir/ana_combined.R
# 		echo "mafsInRegion -outDir $bedfile_new $aln_outdir $maffile" >> $cmdlog
# 		mafsInRegion -outDir $bedfile_new $aln_outdir $maffile
# 		echo "perl $program_dir/combined_maf_1.pl  $aln_outdir $bedfile_new > $log_file" >> $cmdlog
# 		perl $program_dir/combined_maf_1.pl  $aln_outdir $bedfile_new > $log_file
# 	else
# 		echo "cat $aln_outdir/*-aln > ${prj}/homoseq.slim.aln" >> $cmdlog
# 		cat $aln_outdir/*-aln > ${prj}/homoseq.slim.aln
# 		echo "break" >> $cmdlog
# 		break
# 	fi
# done
#-------------------------------------------------- 

if [ ! -e "$prj/homo_image" ] ; then
	echo "mkdir $prj/homo_image" >> $cmdlog
	mkdir $prj/homo_image
else
	echo "rm $prj/homo_image/*" >> $cmdlog
	rm $prj/homo_image/*
fi

cat $aln_outdir/*-aln > ${prj}/homoseq.slim.aln

cd $prj/homo_image
	echo "cat ../homoseq.mirna.fas | RNAfold --noPS -T $TEMP -d0| grep -A2 '>' | grep -v '\-\-' | awk '{print }' > homo.fas.ss" >> ../$cmdlog
	cat ../homoseq.mirna.fas | RNAfold --noPS -T $TEMP -d0| grep -A2 '>' | grep -v '\-\-' | awk '{print }' > homo.fas.ss
	echo "cat homo.fas.ss | RNAplot -o svg" >> ../$cmdlog
	cat homo.fas.ss | RNAplot -o svg > image.id
cd - > /dev/null

echo "perl $program_dir/seq_from_aln.pl $prj/homoseq.slim.aln $prj/homoseq.slim.clustalw $prj/homoseq.slim.fas" >> $cmdlog
perl $program_dir/seq_from_aln.pl $prj/homoseq.slim.aln $prj/homoseq.slim.clustalw $prj/homoseq.slim.fas
#--------------------------------------------------
# perl $program_dir/add_all_fasta.pl $prj $prj/homoseq.slim.fas $prj/homoseq.mirna.fas > $prj/homoseq.mirna.fas
#-------------------------------------------------- 

if [[ -e $prj/homoseq.mirna.*ebwt ]]; then rm $prj/homoseq.mirna.*ebwt; fi
bowtie-build -f $prj/homoseq.mirna.fas $prj/homoseq.mirna > $prj/bowtie-build.log
if [ -e $reads ]; then
	echo "bowtie -f -v 1 -a --best --strata $prj/homoseq.mirna $reads -p $CPU > $prj/homoseq.mirna.bwt" >> $cmdlog
	bowtie -f -v 1 -a --best --strata $prj/homoseq.mirna $reads -p $CPU > $prj/homoseq.mirna.bwt
	bowtie -f -v 1 -a --best --strata $hairpin $reads -p $CPU > $prj/homoseq.haripin.bwt
else
	echo "touch $prj/homoseq.mirna.bwt" >> $cmdlog
	touch $prj/homoseq.mirna.bwt
fi

echo "perl $program_dir/svgShowMapDensity.pl $projname $prj/homoseq.mirna.fas $prj/homoseq.mirna.bwt homo" >> $cmdlog
perl $program_dir/svgShowMapDensity.pl $projname $prj/homoseq.mirna.fas $prj/homoseq.mirna.bwt homo

echo "perl $program_dir/mirna_tag_aln_homoseq.pl $prj/homoseq.slim.clustalw $prj/homoseq.mirna.bwt $prj/homoseq.mirna.fas $major_id $prj/$other_mature_new > $prj/homoseq.mirna.map" >> $cmdlog
perl $program_dir/mirna_tag_aln_homoseq.pl $prj/homoseq.slim.clustalw $prj/homoseq.mirna.bwt $prj/homoseq.mirna.fas $major_id $prj/$other_mature_new > $prj/homoseq.mirna.map

echo "perl $program_dir/analysis_filter.pl $hairpin_seq $mature $prj/homoseq.hairpin.bwt > $prj/homoseq.statistic" >> $cmdlog
perl $program_dir/analysis_filter.pl $hairpin_seq $mature $prj/homoseq.hairpin.bwt > $prj/homoseq.statistic

echo "perl $program_dir/conservation.pl -i $prj/homoseq.slim.clustalw -f $hairpin_seq -m $mature -s $major_id -p $projname -o $prj/homoseq.mirna.kmir 2>/dev/null" >> $cmdlog
perl $program_dir/conservation.pl -i $prj/homoseq.slim.clustalw -f $hairpin_seq -m $mature -s $major_id -p $projname -o $prj/homoseq.mirna.kmir 2>/dev/null

echo ""
echo ""
echo "Homolog searching successfully done."
