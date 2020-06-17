# PughLab pipeline-suite (version 2.0)

## Introduction
This is a collection of pipelines to be used for NGS (both DNA and RNA) analyses, from alignment to variant calling.

Start by creating a clone of the repository:

<pre><code>cd /path/to/some/directory
git clone https://github.com/pughlab/pipeline-suite/
</code></pre>

## Set up config files
There are example config files located in the "configs" folder:
- data configs:
  - fastq_dna_config.yaml and fastq_rna_config.yaml, can be generated using create_fastq_yaml.pl, however this is dependent on filenames being in the expected format (otherwise, just copy the examples!)
  - bam_config.yaml, generated by any tool which outputs BAMs that are required for downstream steps

- master (pipeline) configs:
  - master configs must specify common parameters, including:
    - project name
    - path to desired output directory (will be created if this is the initial run)
    - flag for del_intermediates (either Y or N)
    - flag for dry run (either Y or N)
    - HPC driver (for job submission)
    - path to individual tool configs
 
- individual tool configs:
  - all tool configs must specify:
    - desired versions of tools
    - reference (file or directory) and ref_type (hg19 or hg38)
    - memory and run time parameters for each step

### RNA-Seq
  - star_aligner_config.yaml, specifies:
    - path to STAR reference directory
    - sequencing centre and platform information (for BAM header)
    - optional step: mark_dup (either Y or N)

  - fusioncatcher_config.yaml, specifies:
    - path to Fusioncatcher reference directory

   - rsem_tool_config.yaml, specifies:
    - path/stem to RSEM reference directory
    - strandedness type (probably reverse, other options: forward or none)

   - star_fusion_tool_config.yaml, specifies:
    - path/stem to STAR-Fusion reference directory
    - path to tool (because it isn't currently installed as a module)
    - optional step: FusionInspect (either inspect, validate; if not wanted, leave blank)
  
   - gatk_tool_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to dbSNP file (if undefined, a default will be used)

   - haplotype_caller_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to vcf2maf.pl
    - path to VEP (tool/version, cache data)
    - path to ExAC data (for filtering/annotating with population allele frequencies)

### DNA-Seq
  - bwa_aligner_config.yaml, specifies:
    - path to bwa-indexed reference
    - sequencing centre and platform information (for BAM header)
    - optional step: mark_dup (either Y or N)

  - gatk_tool_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (such as bed file for exome capture kit)
    - path to dbSNP file (if undefined, a default will be used)

   - haplotype_caller_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to dbSNP file (if undefined, a default will be used)

   - mutect_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to vcf2maf.pl
    - path to VEP (tool/version, cache data)
    - path to ExAC data (for filtering/annotating with population allele frequencies)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to dbSNP file (if undefined, a default will be used)
    - path to COSMIC file (if desired)
    - path to panel of normals (optional if developed elsewhere)

   - mutect2_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to vcf2maf.pl
    - path to VEP (tool/version, cache data)
    - path to ExAC data (for filtering/annotating with population allele frequencies)
    - path to target intervals (exome capture kit [bed], if defined)
    - path to dbSNP file (if undefined, a default will be used)
    - path to COSMIC file (if desired)
    - path to panel of normals (optional if developed elsewhere)

   - varscan_config.yaml, specifies:
    - path to reference genome (requires .fa, .dict and .fai files)
    - path to vcf2maf.pl
    - path to VEP (tool/version, cache data)
    - path to ExAC data (for filtering/annotating with population allele frequencies)
    - path to target intervals (exome capture kit [bed], if defined)

## Running a pipeline
If you are running these pipelines on the cluster, be sure to first load perl!

### Prepare a config file containing paths to FASTQ files:
<pre><code>cd /path/to/some/directory/pipeline-suite/

module load perl
perl create_fastq_yaml.pl -i /path/to/sampleInfo.txt -d /path/to/fastq/directory/ -o /path/to/fastq_config.yaml -t {dna|rna}
</code></pre>

Where sampleInfo.txt is a tab-separate table containing two columms, and each row represents a single sample:

| Patient.ID | Sample.ID  |
| ---------- | ---------- |
| Patient1   | Patient1-N |
| Patient1   | Patient1-T |
| Patient2   | Patient2-T |

The assumption is that each FASTQ file will follow a similar naming convention, with Sample.ID used to identify files
for this sample, and lane information is pulled from the file name 
(for example: Patient1-N_135546_D00355_0270_AATCCGTC_L001.R1.fastq.gz, is a normal, library Patient1-N, lane 135546_D00355_0270_AATCCGTC_L001, R1).

For both the DNA- and RNA-Seq pipelines, all tools listed in the master config will be run and each tool can be run separately if desired. The 'master' pipelines will write out the perl commands for each individual step for easy reference.

See ./configs/dna_fastq_config.yaml and ./configs/rna_fastq_config.yaml for examples.

Also, be sure to run FASTQC to verify fastq quality prior to running downstream pipelines:
<pre><code>
perl collect_fastqc_metrics.pl -c /path/to/fastq_config.yaml -t /path/to/fastqc_tool_config.yaml --dna (or --rna)
</code></pre>

### DNA pipeline:
<pre><code>cd /path/to/git/pipeline-suite/

module load perl

perl pughlab_dnaseq_pipeline.pl -t /path/to/dna_pipeline_config.yaml -d /path/to/dna_fastq_config.yaml
</code></pre>

This will generate the directory structure in the output directory (provided in /path/to/dna_pipeline_config.yaml), including a "logs/run_DNA_pipeline_TIMESTAMP/" directory containing a file "run_DNASeq_pipeline.log" which lists the individual tool commands; these can be run separately if "dry_run: Y" or in the event of a failure at any stage and you don't need to re-run the entire thing (***Note:*** doing so would not regenerate files that already exist).

If your project is quite large (>20 samples), you may prefer to run the alignments and variant calling steps separately (ie, produce the final GATK-processed bams and remove BWA intermediates to free up space). To accomplish this, simply set preprocessing: Y and variant_calling: N in the dna_pipeline_config.yaml. However, since the variant calling steps are best run as a single cohort, be sure to combine all of the gatk_bam_config.yamls prior to running variant calling (ie, from the GATK directory: cat \*/gatk_bam_config.yaml | awk 'NR <= 1 || !/^---/' > combined_gatk_bam_config.yaml).

# Preprocessing steps:
# run BWA to align to a reference genome
</code></pre>
perl bwa.pl -t /path/to/bwa_aligner_config.yaml -d /path/to/fastq_dna_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N}
</code></pre>

This will again write individual commands to file: /path/to/output/directory/BWA/TIMESTAMP/logs/run_BWA_pipeline.log

# run GATK indel realignment and base quality score recalibration
</code></pre>
perl gatk.pl --dna -t /path/to/gatk_tool_config.yaml -d /path/to/bwa_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from bwa.pl }

</code></pre>

# get BAM QC metrics, including coverage, contamination estimates and callable bases
</code></pre>
perl contest.pl -t /path/to/bamqc_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl }

perl get_coverage.pl -t /path/to/bamqc_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl }
</code></pre>

# Variant calling steps:
# run GATK's HaplotypeCaller to produce gvcfs
</code></pre>
perl haplotype_caller.pl --dna -t /path/to/haplotype_caller_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl }

perl genotype_gvcfs.pl -t /path/to/haplotype_caller_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from haplotype_caller.pl }
</code></pre>

# run GATK's MuTect (v1) to produce somatic SNV calls
</code></pre>
Create a panel of normals:
perl mutect.pl -t /path/to/mutect_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --create-panel-of-normals --depends { optional: final job ID from gatk.pl }

Generate somatic SNV calls:
perl mutect.pl -t /path/to/mutect_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl or above panel of normal creation } --pon /path/to/panel_of_normals.vcf { optional: can also be specified in mutect_config.yaml if created elsewhere }
</code></pre>

# run GATK's MuTect2 to produce somatic SNV calls
</code></pre>
Create a panel of normals:
perl mutect2.pl -t /path/to/mutect2_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --create-panel-of-normals --depends { optional: final job ID from gatk.pl }

Generate somatic SNV calls:
perl mutect2.pl -t /path/to/mutect2_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl or above panel of normal creation } --pon /path/to/panel_of_normals.vcf { optional: can also be specified in mutect_config.yaml if created elsewhere }
</code></pre>

# run VarScan to produce SNV and CNA calls
</code></pre>
Run T/N pairs and create a panel of normals:
perl varscan.pl --mode paired -t /path/to/varscan_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl }

Run tumour-only samples with a panel of normals (can also be run without, but germline filtering will not be performed):
perl varscan.pl --mode unpaired -t /path/to/varscan_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from gatk.pl or above panel of normals creation } --pon /path/to/panel_of_normals.vcf { optional: can also be specified in mutect_config.yaml if created elsewhere }
</code></pre>

### RNA pipeline:
<pre><code>cd /path/to/git/pipeline-suite/

module load perl

perl pughlab_rnaseq_pipeline.pl -t /path/to/master_rna_config.yaml -d /path/to/fastq_rna_config.yaml
</code></pre>

This will generate the directory structure in the output directory (provided in /path/to/master_rna_config.yaml), including a "logs/run_RNA_pipeline_TIMESTAMP/" directory containing a file "run_RNASeq_pipeline.log" which lists the individual tool commands; these can be run separately if "dry_run: Y" or in the event of a failure at any stage and you don't need to re-run the entire thing (although doing so would not regenerate files that already exist).

# run STAR to align to a reference genome
</code></pre>
perl star.pl -t /path/to/star_aligner_config.yaml -d /path/to/fastq_rna_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} -p PROJECTNAME
</code></pre>

This will again write individual commands to file: /path/to/output/directory/STAR/TIMESTAMP/logs/run_STAR_pipeline.log

# run Fusioncatcher on raw FASTQ data
</code></pre>
perl fusioncatcher.pl -t /path/to/fusioncatcher_config.yaml -d /path/to/fastq_rna_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} -p PROJECTNAME
</code></pre>

# run RSEM on STAR-aligned BAMs
</code></pre>
perl rsem.pl -t /path/to/rsem_expression_config.yaml -d /path/to/star_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} -p PROJECTNAME --depends { optional: final job ID from star.pl }
</code></pre>

# run STAR-Fusion on STAR-aligned BAMs
</code></pre>
perl star_fusion.pl -t /path/to/star_fusion_config.yaml -d /path/to/star_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} -p PROJECTNAME --depends { optional: final job ID from star.pl }
</code></pre>

# run GATK split CIGAR, indel realignment and base quality score recalibration on MarkDup BAMs
</code></pre>
perl gatk.pl --rna -t /path/to/gatk_tool_config.yaml -d /path/to/star_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} --depends { optional: final job ID from star.pl }
</code></pre>

# run GATK HaplotypeCaller, variant filtration and annotataion
</code></pre>
perl haplotype_caller.pl --rna -t /path/to/haplotype_caller_config.yaml -d /path/to/gatk_bam_config.yaml -o /path/to/output/directory -h slurm -r {Y|N} -n {Y|N} -p PROJECTNAME --depends { optional: final job ID from gatk.pl }
</code></pre>

These will again write individual commands to file: /path/to/output/directory/TOOL/TIMESTAMP/logs/run_TOOL_pipeline.log

### Resuming a run:
If the initial run is unsuccessful or incomplete, check the logs to identify the problem - it is most likely due to insufficient memory or runtime allocation. In this case, update the necessary parameters for the affected stage in the tool_config.yaml. 

Now, rerun individual tool commands (as found in /path/to/output/directory/logs/TIMESTAMP/run_RNASeq_pipeline.log).

## Output
Each step/perl script will produce the following directory structure and output files:

```
/path/to/output/directory/
└── TOOL
    └── TIMESTAMP
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

# RNASeq
- star.pl
  - will use collect_rnaseqc_output.R to collect RNASeQC metrics from all processed samples
  - output includes:
    - DATE_projectname_rnaseqc_output.tsv (qc metrics)
    - DATE_projectname_rnaseqc_Pearson_correlations.tsv (sample-sample correlations)
- rsem.pl
  - will use collect_rsem_output.R to collect expression data from all processed samples
  - output includes gene/isoform x sample matrices:
    - DATE_projectname_gene_expression_FPKM.tsv
    - DATE_projectname_gene_expression_TPM.tsv
    - DATE_projectname_isoform_expression_FPKM.tsv
    - DATE_projectname_isoform_expression_TPM.tsv
- star_fusion.pl
  - will use collect_star-fusion_output.R to collect fusions from all processed samples
  - output includes:
    - DATE_projectname_star-fusion_output_long.tsv (concatenated output)
    - DATE_projectname_star-fusion_output_wide.tsv (fusion x sample matrix)
- fusioncatcher.pl
  - will use collect_fusioncatcher_output.R to collect fusions from all processed samples
  - output includes:
    - DATE_projectname_fusioncatcher_output_long.tsv (concatenated output)
    - DATE_projectname_fusioncatcher_output_wide.tsv (fusion x sample matrix)
    - DATE_projectname_fusioncatcher_viral_counts.tsv (species x sampel matrix)
- haplotype_caller.pl
  - will use collect_snv_output.R to collect high-confidence SNV calls from all processed samples
  - output includes:
    - DATE_projectname_variant_by_patient.tsv (snv [chr/pos/ref/alt/gene] x sample matrix)
    - DATE_projectname_gene_by_patient.tsv (gene x sample matrix)
