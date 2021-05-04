# PughLab pipeline-suite (version 0.4.1)

## Introduction
This is a collection of pipelines to be used for NGS (both DNA and RNA) analyses, from alignment to variant calling.

Start by creating a clone of the repository:

<pre><code>cd /path/to/some/directory
git clone https://github.com/pughlab/pipeline-suite/
</code></pre>

Additionally, the report generation portion of this tool requires installation of the BPG plotting package for R:
https://CRAN.R-project.org/package=BoutrosLab.plotting.general

## Set up config files
There are example config files located in the "configs" folder:
- data configs:
  - fastq_dna_config.yaml and fastq_rna_config.yaml, can be generated using create_fastq_yaml.pl, however this is dependent on filenames being in the expected format (otherwise, just copy the examples!)
  - bam_config.yaml, generated by any tool which outputs BAMs that are required for downstream steps

- pipeline configs (dna_pipeline_config.yaml and rna_pipeline_config.yaml):
  - these specify common parameters, including:
    - project name
    - sequencing type (wgs, exome, rna or targeted), sequencing center and platform
    - path to desired output directory (will be created if this is the initial run)
    - paths to tool-specific reference files/directories and ref_type (hg19 or hg38)
    - desired versions of tools
    - for each tool, memory and run time parameters for each step

### RNA-Seq
NOTE: The RNA-Seq pipeline is currently only configured for use with GRCh38 reference. It will, in theory, run on GRCh37, however you must set up the reference files as needed and update the config file as necessary!

  - star requires:
    - path to STAR reference directory

  - fusioncatcher requires:
    - path to Fusioncatcher reference directory

   - rsem requires:
    - path/stem to RSEM reference directory
    - strandedness type (probably reverse, other options: forward or none)

   - star_fusion requires:
    - path/stem to STAR-Fusion reference directory
    - path to tool (because it isn't currently installed as a module)
    - optional step: FusionInspect (either inspect, validate; if not wanted, leave blank)
  
   - gatk requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to dbSNP file (if undefined, a default will be used)

   - haplotype_caller requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to vcf2maf.pl
    - path to VEP (tool/version, cache data)
    - path to ExAC data (for filtering/annotating with population allele frequencies)

### DNA-Seq
  - bwa requires:
    - path to bwa-indexed reference
    - optional step: mark_dup (either Y or N)

  - gatk requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (such as bed file for exome capture kit) if seq_type is exome or targeted
    - path to dbSNP file (if undefined, a default will be used)

   - bamqc requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to hapmap/SNP file with population frequencies (for ContEst)
    - path to gnomAD/SNP vcf file with allele frequencies (must have accompanying .idx file)
    - path to target intervals (such as bed file for exome capture kit) if seq_type is exome or targeted

   - haplotype_caller requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to dbSNP file (if undefined, a default will be used)
    - path to known pathogenic germline variants (ie, from TCGA)

   - annotate requires:
    - path to vcf2maf.pl
    - path to VEP (tool/version, cache data)
    - path to ExAC data (for filtering/annotating with population allele frequencies)

   - mutect requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to dbSNP file (if undefined, a default will be used)
    - path to COSMIC file (if desired)
    - path to panel of normals (optional if developed elsewhere)

   - mutect2 requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - comma separated list of chromosomes to run (optional)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to dbSNP file (if undefined, a default will be used)
    - path to COSMIC file (if desired)
    - path to panel of normals (optional if developed elsewhere)

   - strelka requires:
    - sequence type (one of exome, targeted, rna or wgs)
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to panel of normals (optional if developed elsewhere)

   - varscan requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to sequenza.R script
    - path to target intervals (exome capture kit [bed], if defined)
    - path to panel of normals (optional if developed elsewhere)

   - somaticsniper requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to panel of normals (optional)

   - vardict requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to panel of normals (optional)

   - gatk_cnv requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to gnomAD/SNP vcf file with allele frequencies (must have accompanying .idx file)

   - delly requires:
    - path to reference genome (requires .fa, .dict and .fai files)

   - mavis requires:
    - path to reference genome (requires .fa, .dict and .fai files)
    - paths to mavis references (annotations, masking, aligner, etc.)

   - other tools:
    - msi_run: Y (or N) to run msi sensor

## Running a pipeline

### Prepare a yaml file containing paths to FASTQ files:
See ./configs/dna_fastq_config.yaml and ./configs/rna_fastq_config.yaml for examples.

### Check FASTQs prior to running:
Be sure to run FASTQC to verify fastq quality prior to running downstream pipelines. In particular, ensure read length is consistent, GC content is similar (typically between 40-60%) and files are unique (no duplicated md5sums):
<pre><code>perl collect_fastqc_metrics.pl \
-d /path/to/fastq_config.yaml \
-t /path/to/fastqc_tool_config.yaml \
-c slurm \
{optional: --rna, --dry-run }
</code></pre>

### Prepare interval files (ie, for WXS):
For WXS or targeted-sequencing panels, a bed file containing target regions should be provided (listing at minimum: chromosome, start and end positions). Variant calling pipelines MuTect and Mutect2 will add 100bp of padding to each region provided. For consistency, this padding must be manually added prior to variant calling with other tools (ie, Strelka, SomaticSniper, VarDict and VarScan). This will additionally create a bgzipped version required by Strelka.

<pre><code>perl format_interval_bed.pl \
-b /path/to/base/intervals.bed \
-r /path/to/reference.fa
</code></pre>

This will produce a padded bed file in the same directory as the original bed file (if the original file is /path/to/intervals.bed then this will produce /path/to/intervals_padding100bp.bed and intervals_padding100bp.bed.gz) and a picard-style intervals.list file.

### DNA pipeline:
<pre><code>cd /path/to/git/pipeline-suite/

module load perl

perl pughlab_dnaseq_pipeline.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/dna_fastq_config.yaml \
--preprocessing \
--variant_calling \
--create_report \
-c slurm \
--remove 
</code></pre>

This will generate the directory structure in the output directory (provided in /path/to/dna_pipeline_config.yaml), including a "logs/run_DNA_pipeline_TIMESTAMP/" directory containing a file "run_DNASeq_pipeline.log" which lists the individual tool commands; these can be run separately if "--dry-run" is set, or in the event of a failure at any stage and you don't need to re-run the entire thing (***Note:*** doing so would not regenerate files that already exist).

If your project is quite large (>20 samples), you may prefer to run the preprocessing steps in batches (to produce the final GATK-processed bams and remove BWA intermediates to free up space). To accomplish this, subset the data config (ie, path/to/dna_fastq_config.yaml) and only indicate --preprocessing in the command. Since the variant calling steps are best run as a single cohort, be sure to combine all of the partial gatk_bam_config.yamls prior to running variant calling:

<pre><code>cd /path/to/output/GATK/

cat gatk_bam_config\*.yaml | awk 'NR <= 1 || !/^---/' > combined_gatk_bam_config.yaml

perl pughlab_dnaseq_pipeline.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/combined_gatk_bam_config.yaml \
--variant_calling \
--create_report \
-c slurm \
--remove 
</code></pre>

## To run individual steps:

### run BWA to align to a reference genome
<pre><code>perl bwa.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/fastq_dna_config.yaml \
-o /path/to/output/directory \
-b /path/to/output/bam.yaml \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

This will again write individual commands to file: /path/to/output/directory/BWA/logs/run_BWA_pipeline.log

### run GATK indel realignment and base quality score recalibration
<pre><code>perl gatk.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/bwa_bam_config.yaml \
-o /path/to/output/directory \
-b /path/to/output/bam.yaml \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### get BAM QC metrics, including coverage, contamination estimates and callable bases
<pre><code>perl contest.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

perl get_sequencing_metrics.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

perl get_coverage.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### Variant calling steps:
### run GATK's HaplotypeCaller to produce gvcfs
<pre><code>Run HaplotypeCaller on each sample separately:
perl haplotype_caller.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

Combine and Genotype GVCFs:
perl genotype_gvcfs.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

Annotate and Filter using CPSR:
perl annotate_germline.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-i /path/to/genotype_gvcfs/final/output/directory \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run GATK's MuTect (v1) to produce somatic SNV calls
<pre><code>Create a panel of normals (germline calls + sequencing artefacts):
perl mutect.pl \
--create-panel-of-normals \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

Generate somatic SNV calls:
perl mutect.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--pon /path/to/panel_of_normals.vcf { optional if not using the one created here: can also be specified in dna_pipeline_config.yaml if created elsewhere } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run GATK's MuTect2 to produce somatic SNV calls
<pre><code>Create a panel of normals (germline calls + sequencing artefacts):
perl mutect2.pl \
--create-panel-of-normals \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

Generate somatic SNV and INDEL calls:
perl mutect2.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--pon /path/to/panel_of_normals.vcf { optional if not using the one created here: can also be specified in dna_pipeline_config.yaml if created elsewhere } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

A few notes about Mutect2: Some samples (WGS and some WXS samples) will have exceptionally long run times. One solution is to run Mutect2 *per-chromosome*, however this alters the statistical models applied and thus may produce a different set of variants. Currently, stringent filtering plus the final ensemble approach typically make these differences irrevelant but it is something to be aware of.

### run VarScan to produce SNV and CNA calls
<pre><code>Run T/N pairs to generate CNA calls, plus germline and somatic SNV and INDEL calls. Then creates a panel of normals from the germline calls. Finally, run T-only samples with germline filtering using the panel of normals:
perl varscan.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--pon /path/to/panel_of_normals.vcf { optional if not using the one created here: can also be specified in dna_pipeline_config.yaml if created elsewhere } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

Use VarScan output to run Sequenza with gamma tuning for optimized SCNA calls:
perl run_sequenza_with_optimal_gamma.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

</code></pre>

### run Strelka to produce SNV and Manta SV calls
<pre><code>Create a panel of normals (germline calls):
perl strelka.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--create-panel-of-normals \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }

Generate somatic SNV and INDEL calls, as well as SV calls from Manta:
perl strelka.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--pon /path/to/panel_of_normals.vcf { optional if not using the one created here: can also be specified in dna_pipeline_config.yaml if created elsewhere } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run SomaticSniper to produce SNV calls
<pre><code>Generate somatic SNV calls:
perl somaticsniper.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--pon /path/to/panel_of_normals.vcf { optional; can also be specified in dna_pipeline_config.yaml if created elsewhere } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

SomaticSniper will **ONLY** run on tumour samples with a matched normal, and will **ONLY** produce somatic SNV calls (no panel of normals will be generated for this caller). If you wish to perform additional germline filtering, you may provide a panel of normals developed elsewhere.

### run VarDict to produce variant calls
<pre><code>Run T/N pairs to generate CNA calls, plus germline and somatic SNV and INDEL calls. Then creates a panel of normals from the germline calls. Finally, run T-only samples with germline filtering using the panel of normals:
perl vardict.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--pon /path/to/panel_of_normals.vcf { optional if not using the one created here; can also be specified in dna_pipeline_config.yaml if created elsewhere } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run GATK:CNV to produce somatic CNA calls
<pre><code>Generate somatic CNA calls:
perl gatk_cnv.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

GATK:CNV will **ONLY** run if at least one normal sample is provided, but will then run all provided samples (T/N and tumour-only).

### run Delly to produce SV calls
<pre><code>Generate somatic SV calls:
perl delly.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run Mavis to annotate Delly and Manta SV calls
<pre><code>Combine and annotate SV calls from Delly and Manta:
perl mavis.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
--manta /path/to/strelka/directory \
--delly /path/to/delly/directory \
--rna /path/to/gatk_rnaseq_bam_config.yaml { optional if pughlab_rnaseq_pipeline.pl was run previously } \
--starfusion /path/to/starfusion/directory { optional if pughlab_rnaseq_pipeline.pl was run previously } \
--fusioncatcher /path/to/fusioncatcher/directory { optional if pughlab_rnaseq_pipeline.pl was run } \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run MSI-Sensor
<pre><code>Generate MSI estimates:
perl msi_sensor.pl \
-t /path/to/dna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### create final report
<pre><code>Create a pretty report summarizing pipeline output:
perl pughlab_pipeline_auto_report.pl \
-t /path/to/dna_pipeline_config.yaml \
-d DATE \
-c slurm \
--dry-run { if this is a dry-run; NOTE that this will fail if the above pipeline has not completed } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### Final notes on the DNA pipeline: ###
SomaticSniper will not run if no matched normals are provided; set run: N in dna_pipeline_config.yaml
GATK_CNV requires at least 1 matched normal, but would ideally have many (for the panel of normals); set run: N in dna_pipeline_config.yaml if normals are unavailable.

Panel of Normals for SNV callers: Whenever possible, variant callers will generate a panel of normals to use for variant filtering. Depending on the tool, these panels list probable germline variants and/or sequencing artefacts.
- MuTect: germline variants and sequencing artefacts, called using --artifact_detection_mode; is applied to all samples
- Mutect2: germline variants and sequencing artefacts, called using --artifact_detection_mode; is applied to all samples
- Strelka: germline variants, called using Strelka's germline workflow; applied to all tumour samples
- VarScan: germline variants as determined by VarScan's processSomatic function; only applied to tumour-only samples
- VarDict: germline variants as determined by VarDict; only applied to tumour-only samples 

VCF2MAF produces very large log files. Once complete, please remove/trim these to free up space! For example
<pre><code>for i in logs/run_vcf2maf_and_VEP_INS-\*/slurm/s\*out; do
  grep -v 'WARNING' $i > $i.trim; rm $i;
done
</code></pre>

### RNA pipeline:
<pre><code>cd /path/to/git/pipeline-suite/

module load perl

perl pughlab_rnaseq_pipeline.pl \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/fastq_rna_config.yaml\
--create-report \
-c slurm \
--remove \
</code></pre>

This will generate the directory structure in the output directory (provided in /path/to/master_rna_config.yaml), including a "logs/run_RNA_pipeline_TIMESTAMP/" directory containing a file "run_RNASeq_pipeline.log" which lists the individual tool commands; these can be run separately if "--dry-run" or in the event of a failure at any stage and you don't need to re-run the entire thing (although doing so would not regenerate files that already exist).

### run STAR to align to a reference genome
<pre><code>perl star.pl \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/fastq_rna_config.yaml \
-o /path/to/output/directory \
-b /path/to/output/bam.yaml \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

This will again write individual commands to file: /path/to/output/directory/STAR/logs/run_STAR_pipeline.log

### run Fusioncatcher on raw FASTQ data
<pre><code>perl fusioncatcher.pl \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/fastq_rna_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run RSEM on STAR-aligned BAMs
<pre><code>perl rsem.pl \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/star_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run STAR-Fusion on STAR-aligned BAMs
<pre><code>perl star_fusion.pl \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/star_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run GATK split CIGAR, indel realignment and base quality score recalibration on MarkDup BAMs
<pre><code>perl gatk.pl \
--rna \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/star/bam_config.yaml \
-o /path/to/output/directory \
-b /path/to/output/bam.yaml \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

### run GATK HaplotypeCaller, variant filtration and annotataion
<pre><code>perl haplotype_caller.pl \
--rna \
-t /path/to/rna_pipeline_config.yaml \
-d /path/to/gatk_bam_config.yaml \
-o /path/to/output/directory \
-c slurm \
--remove \
--dry-run { if this is a dry-run } \
--no-wait { if not a dry-run and you don't want to wait around for it to finish }
</code></pre>

These will again write individual commands to file: /path/to/output/directory/TOOL/logs/run_TOOL_pipeline.log

### create final report
<pre><code>perl pughlab_pipeline_auto_report.pl \
-t /path/to/rna_pipeline_config.yaml \
-d DATE \
-c slurm \
--dry-run
</code></pre>

### Resuming a run:
If the initial run is unsuccessful or incomplete, check the logs to identify the problem - it is most likely due to insufficient memory or runtime allocation. In this case, update the necessary parameters for the affected stage in the tool_config.yaml. 

Now, rerun individual tool commands (as found in /path/to/output/directory/logs/TIMESTAMP/run_RNASeq_pipeline.log).

## Output
Each step/perl script will produce the following directory structure and output files:

```
/path/to/output/directory/
└── TOOL
    ├── bam_config.yaml (bwa.pl, star.pl, gatk.pl)
    ├── logs
    │   └── stage1_patient1
    │       ├── script.sh
    │       └── slurm
    ├── patient1
    │   ├── sample1
    │   │   ├── input_links
    │   │   └── output.bam
    │   └── sample2
    ├── patient2
    └── combined_output.tsv (see below)
```

On completion, certain steps will collate and format the tool output from all patients:

# DNA
- contest.pl
  - will use collect_contest_output.R to collect contamination estimates from all processed samples
  - output includes: DATE_projectname_ContEst_output.tsv (combined META and READGROUP estimates)
- get_coverage.pl
  - will use collect_coverage_output.R to collect depth of coverage metrics from all processed samples
  - output includes:
    - DATE_projectname_Coverage_summary.tsv (summary metrics including mean, median, % above 15)
    - DATE_projectname_Coverage_statistics.tsv (N bases with X read depth [from 0 to 500])
  - will use count_callable_bases.R to collect total callable base details:
    - DATE_projectname_total_bases_covered.tsv
    - DATE_projectname_CallableBases.RData
- genotype_gvcfs.pl
  - will use collect_germline_genotypes.R to collect genotypes from all processed samples
  - output includes:
    - DATE_projectname_germline_genotypes.tsv (position x sample matrix)
    - DATE_projectname_germline_correlation.tsv (sample x sample matrix)
- mutect.pl, mutect2.pl, varscan.pl, vardict.pl, somaticsniper.pl and strelka.pl
  - will use collect_snv_output.R to collect somatic SNV/INDEL calls from all processed samples
  - output includes:
    - DATE_projectname_mutations_for_cbioportal.tsv (SNV and INDEL calls in format required by cBioportal)
- varscan.pl
  - will use collect_sequenza_output.R to collect CNV calls from all processed samples
  - output includes:
    - DATE_projectname_Sequenza_ploidy_purity.tsv (*best* purity and ploidy estimates)
    - DATE_projectname_Sequenza_cna_gene_matrix.tsv (thresholded CN status; gene x patient matrix; a gene is considered to have a CNA if >20 bases overlap with a discovered segment)
    - DATE_projectname_Sequenza_ratio_gene_matrix.tsv (log2(depth.ratio); gene x patient matrix; a gene is considered to have a CNA if >20 bases overlap with a discovered segment)
    - DATE_projectname_segments_for_gistic.tsv and DATE_projectname_markerss_for_gistic.tsv (log2(depth.ratio) for input to GISTIC2.0)
    - DATE_projectname_segments_for_cbioportal.tsv (log2(depth.ratio) formatted for cbioportal)
- mavis.pl
  - will use collect_mavis_output.R to collect SV calls from all samples
  - output includes:
    - DATE_projectname_mavis_output.tsv (concatenated output across samples)
    - DATE_projectname_svs_for_cbioportal.tsv (SVs in format required by cBioportal)
- msi_sensor.pl
  - will use collect_msi_estimates.R to collect MSI output from all samples: DATE_projectname_msi_estimates.tsv 

# RNASeq
- star.pl
  - will use collect_rnaseqc_output.R to collect RNASeQC metrics from all processed samples
  - output includes:
    - DATE_projectname_rnaseqc_output.tsv (qc metrics)
    - DATE_projectname_rnaseqc_Pearson_correlations.tsv (sample-sample correlations)
- rsem.pl
  - will use collect_rsem_output.R to collect expression data from all processed samples
  - output includes gene/isoform x sample matrices:
    - DATE_projectname_gene_expression_TPM.tsv
    - DATE_projectname_mRNA_expression_TPM_for_cbioportal.tsv (RNA expression values in format required by cBioportal. NOT CN/ploidy adjusted!)
    - DATE_projectname_mRNA_TPM_zscores_for_cbioportal.tsv (RNA expression zscores in format required by cBioportal. NOT CN/ploidy adjusted!)
    - DATE_projectname_rsem_expression_results.RData
- star_fusion.pl
  - will use collect_star-fusion_output.R to collect fusions from all processed samples
  - output includes:
    - DATE_projectname_star-fusion_output_long.tsv (concatenated output)
    - DATE_projectname_star-fusion_output_wide.tsv (fusion x sample matrix)
    - DATE_projectname_star-fusion_for_cbioportal.tsv (SVs in format required by cBioportal)
- fusioncatcher.pl
  - will use collect_fusioncatcher_output.R to collect fusions from all processed samples
  - output includes:
    - DATE_projectname_fusioncatcher_output_long.tsv (concatenated output)
    - DATE_projectname_fusioncatcher_output_wide.tsv (fusion x sample matrix)
    - DATE_projectname_fusioncatcher_for_cbioportal.tsv (SVs in format required by cBioportal)
    - DATE_projectname_fusioncatcher_viral_counts.tsv (species x sampel matrix)
- haplotype_caller.pl
  - will use collect_snv_output.R to collect high-confidence SNV calls from all processed samples
  - output includes:
    - DATE_projectname_variant_by_patient.tsv (snv [chr/pos/ref/alt/gene] x sample matrix)
    - DATE_projectname_gene_by_patient.tsv (gene x sample matrix)
    - DATE_projectname_mutations_for_cbioportal.tsv (SNV and INDEL calls in format required by cBioportal)
