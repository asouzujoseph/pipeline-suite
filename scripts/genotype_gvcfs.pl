#!/usr/bin/env perl
### genotype_gvcfs.pl ##############################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);
use IO::Handle;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $known_1000g, $hapmap, $omni, $known_mills, $dbsnp);

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to filter germline/somatic SNVs/INDELs from haplotypecaller
# 1.1		sprokopec	added help msg and cleaned up code
# 1.2		sprokopec	minor updates for tool config

### USAGE ##########################################################################################
# genotype_gvcfs.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_runT
#
# where:
#	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
#	GATK-processed BAMs, generated by gatk.pl)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	-c indicates hpc driver (ie, slurm)
#	--remove indicates that intermediates will be removed
#	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to run GENOTYPE GVCFs
sub create_genotype_gvcfs_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		tmp_dir		=> undef,
		java_mem	=> undef,
		@_
		);

	my $gvcf_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T GenotypeGVCFs',
		'-R', $reference,
		'-V', $args{input},
		'--out', $args{output}
		);
	
	return($gvcf_command);
	}

# format command to run VQSR
sub create_vqsr_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		var_type	=> undef,
		tmp_dir		=> undef,
		java_mem	=> undef,
		@_
		);

	my $vqsr_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T VariantRecalibrator',
		'-R', $reference,
		'-input', $args{input},
		'-recalFile', $args{output_stem} . '.recal',
		'-tranchesFile', $args{output_stem} . '.tranches'
		);

	if ('INDEL' eq $args{var_type}) {
		$vqsr_command .= ' ' . join(' ',
			'-resource:mills,known=true,training=true,truth=true,prior=12.0', $known_mills,
			'-an DP -an FS -an MQRankSum -an ReadPosRankSum -mode INDEL',
			'-tranche 100.0 -tranche 99.9 -tranche 99.0 -tranche 90.0 --maxGaussians 2'
			);

		} elsif ('SNP' eq $args{var_type}) {

		$vqsr_command .= ' ' . join(' ',
			'-resource:hapmap,known=false,training=true,truth=true,prior=15.0', $hapmap,
			'-resource:omni,known=false,training=true,truth=true,prior=12.0', $omni,
			'-resource:1000G,known=false,training=true,truth=false,prior=10.0', $known_1000g,
			'-resource:dbsnp,known=true,training=false,truth=false,prior=2.0', $dbsnp,
			'-an DP -an QD -an FS -an MQ -an MQRankSum -an ReadPosRankSum -mode SNP --maxGaussians 4'
			);
		}

	return($vqsr_command);
	}

# format command to Apply recalibration
sub create_apply_vqsr_command {
	my %args = (
		input		=> undef,
		vqsr_stem	=> undef,
		output		=> undef,
		var_type	=> undef,
		tmp_dir		=> undef,
		java_mem	=> undef,
		@_
		);

	my $recal_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T ApplyRecalibration',
		'-R', $reference,
		'-input', $args{input},
		'--ts_filter_level 99',
		'-recalFile', $args{vqsr_stem} . '.recal',
		'-tranchesFile', $args{vqsr_stem} . '.tranches',
		'-mode', $args{var_type},
		'-o', $args{output}
		);

	return($recal_command);
	}

sub create_filter_command {
	my %args = (
		input		=> undef,
		tumour_ids	=> undef,
		normal_ids	=> undef,
		output		=> undef,
		@_
		);

	my $filter_command = join(' ',
		"perl $cwd/filter_germline_variants.pl",
		'--vcf', $args{input},
		'--output', $args{output},
		'--reference', $reference
		);

	if (scalar(@{$args{tumour_ids}}) > 0) {
		$filter_command .= " --tumour " . join(',', @{$args{tumour_ids}});
		}

	if (scalar(@{$args{normal_ids}}) > 0) {
		$filter_command .= " --normal " . join(',', @{$args{normal_ids}});
		}

	$filter_command .= "\n\n" . join("\n",
		"md5sum $args{output} > $args{output}.md5",
		"bgzip $args{output}",
		"tabix -p vcf $args{output}.gz"
		);

	return($filter_command);
	}

### MAIN ###########################################################################################
sub main{
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		no_wait			=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'gatk');

	# organize output directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs', 'RUN_GENOTYPE_GVCFS');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_GENOTYPEGVCFs_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	unless ($args{dry_run}) {
		# initiate a file to hold job metrics (ensures that an existing file isn't overwritten by concurrent jobs)
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_GENOTYPEGVCFs_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Filter Germline SNV/INDEL pipeline...\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	if ('hg38' eq $tool_data->{ref_type}) {

		print $log "\n      Using GATK's hg38bundle files: /cluster/tools/data/genomes/human/hg38/hg38bundle/";
		$known_1000g	= '/cluster/tools/data/genomes/human/hg38/hg38bundle/1000G_phase1.snps.high_confidence.hg38.vcf.gz';
		$hapmap		= '/cluster/tools/data/genomes/human/hg38/hg38bundle/hapmap_3.3.hg38.vcf.gz';
		$omni		= '/cluster/tools/data/genomes/human/hg38/hg38bundle/1000G_omni2.5.hg38.vcf.gz';
		$known_mills	= '/cluster/tools/data/genomes/human/hg38/hg38bundle/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz';
		$dbsnp		= '/cluster/tools/data/genomes/human/hg38/hg38bundle/dbsnp_144.hg38.vcf.gz';

		} elsif ('hg19' eq $tool_data->{ref_type}) {

		print $log "\n      Using hg19 variant calling files: /cluster/tools/data/genomes/human/hg19/variantcallingdata/";
		$known_1000g	= '/cluster/tools/data/genomes/human/hg19/variantcallingdata/1000G_phase1.snps.high_confidence.hg19.vcf';
		$hapmap		= '/cluster/tools/data/genomes/human/hg19/variantcallingdata/hapmap_3.3.hg19.vcf';
		$omni		= '/cluster/tools/data/genomes/human/hg19/variantcallingdata/1000G_omni2.5.hg19.vcf';
		$known_mills	= '/cluster/tools/data/genomes/human/hg19/variantcallingdata/Mills_and_1000G_gold_standard.indels.hg19.vcf';
		$dbsnp		= '/cluster/tools/data/genomes/human/hg19/variantcallingdata/dbsnp_138.hg19.vcf';
		}

	if (defined($tool_data->{dbsnp})) {
		print $log "\n      dbSNP: $tool_data->{dbsnp}";
		$dbsnp = $tool_data->{dbsnp};
		} else {
		print $log "\n      dbSNP: using default provided in above path (v138 for hg19; v144 for hg38)";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n\n";

	# set tools and versions
	my $gatk	= 'gatk/' . $tool_data->{gatk_version};
	my $r_version	= 'R/'. $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{haplotype_caller}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $cleanup_cmd, $run_id);
	my @all_jobs;

	# set up some directories
	my $cohort_directory = join('/', $output_directory, 'cohort');
	unless (-e $cohort_directory) { make_path($cohort_directory); }

	my $tmp_directory = join('/', $cohort_directory, 'TEMP');
	unless (-e $tmp_directory) { make_path($tmp_directory); }

	$cleanup_cmd = "rm -rf $tmp_directory";

	my $sample_directory = join('/', $cohort_directory, 'germline_variants');
	unless (-e $sample_directory) { make_path($sample_directory); }

	# First step, find all of the CombineGVCF files
	opendir(HC_OUTPUT, $output_directory) or die "Could not open $output_directory";
	my @combined_gvcfs = grep { /g.vcf.gz$/ } readdir(HC_OUTPUT);
	closedir(HC_OUTPUT);

	my $genotype_run_id = '';
	my $genotype_cmd = "cd $output_directory\n";
	$genotype_cmd .= create_genotype_gvcfs_command(
		input		=> join(' -V ', @combined_gvcfs),
		output		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $parameters->{genotype_gvcfs}->{java_mem}
		);

	$genotype_cmd .= join(' ',
		"\n\nmd5sum", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		">", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.md5'),
		"\n\nbgzip", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		"\ntabix -p vcf", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz')
		);

	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz');

	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.md5'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for GenotypeGVCFs...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_genotype_gvcfs_cohort',
			cmd	=> $genotype_cmd,
			modules	=> [$gatk, 'tabix'],
			max_time	=> $parameters->{genotype_gvcfs}->{time},
			mem		=> $parameters->{genotype_gvcfs}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$genotype_run_id = submit_job(
			jobname		=> 'run_genotype_gvcfs_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $genotype_run_id;
		}

	# Now run VQSR on INDELs
	my $vqsr_indel_run_id = '';
	my $vqsr_cmd_indel = create_vqsr_command(
		var_type	=> 'INDEL',
		input		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz'),
		output_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $parameters->{vqsr}->{java_mem}
		);

	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel.recal');
	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel.tranches');

	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel.recal'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for VQSR (INDELs)...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_vqsr_indels_cohort',
			cmd	=> $vqsr_cmd_indel,
			modules	=> [$gatk],
			dependencies	=> $genotype_run_id,
			max_time	=> $parameters->{vqsr}->{time},
			mem		=> $parameters->{vqsr}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$vqsr_indel_run_id = submit_job(
			jobname		=> 'run_vqsr_indels_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $vqsr_indel_run_id;
		}

	# And finally, apply these recalibrations
	my $apply_indel_recal_run_id = '';
	my $apply_vqsr_indel = create_apply_vqsr_command(
		var_type	=> 'INDEL',
		input		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz'),
		vqsr_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel'),
		output		=> join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $parameters->{apply_vqsr}->{java_mem}
		);

	$apply_vqsr_indel .= join(' ',
		"\n\nmd5sum", join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf'),
		">", join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf.md5')
		);

	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf');

	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf.md5'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for INDEL recalibration...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_apply_indel_recalibration_cohort',
			cmd	=> $apply_vqsr_indel,
			modules	=> [$gatk],
			dependencies	=> $vqsr_indel_run_id,
			max_time	=> $parameters->{apply_vqsr}->{time},
			mem		=> $parameters->{apply_vqsr}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$apply_indel_recal_run_id = submit_job(
			jobname		=> 'run_apply_indel_recalibration_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $apply_indel_recal_run_id;
		}

	# Now run VQSR on SNPs
	my $vqsr_snp_run_id = '';
	my $vqsr_cmd_snp = create_vqsr_command(
		var_type	=> 'SNP',
		input		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz'),
		output_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_snp'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $parameters->{vqsr}->{java_mem}
		);

	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_snp.recal');
	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_snp.tranches');

	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_snp.recal'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for VQSR (SNPs)...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_vqsr_snps_cohort',
			cmd	=> $vqsr_cmd_snp,
			modules	=> [$gatk],
			dependencies	=> $genotype_run_id,
			max_time	=> $parameters->{vqsr}->{time},
			mem		=> $parameters->{vqsr}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$vqsr_snp_run_id = submit_job(
			jobname		=> 'run_vqsr_snps_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $vqsr_snp_run_id;
		}

	# And finally, apply these recalibrations
	my $apply_snp_recal_run_id = '';
	my $apply_vqsr_snp = create_apply_vqsr_command(
		var_type	=> 'SNP',
		input		=> join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf'),
		vqsr_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_snp'),
		output		=> join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $parameters->{apply_vqsr}->{java_mem}
		);

	$apply_vqsr_snp .= join(' ',
		"\n\nmd5sum", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf'),
		">", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.md5'),
		"\n\nbgzip", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf'),
		"\ntabix -p vcf", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.gz')
		);
 
	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.md5'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for SNP recalibration...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_apply_snp_recalibration_cohort',
			cmd	=> $apply_vqsr_snp,
			modules	=> [$gatk, 'tabix'],
			dependencies	=> join(':', $apply_indel_recal_run_id, $vqsr_snp_run_id),
			max_time	=> $parameters->{apply_vqsr}->{time},
			mem		=> $parameters->{apply_vqsr}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$apply_snp_recal_run_id = submit_job(
			jobname		=> 'run_apply_snp_recalibration_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $apply_snp_recal_run_id;
		}

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		my @tumour_ids = keys %{$smp_data->{$patient}->{tumour}};
		my @normal_ids = keys %{$smp_data->{$patient}->{normal}};

		my $filtered_output = join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf');
		if (scalar(@normal_ids) == 0) {
			$filtered_output = join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf');
			}

		my $filter_cmd = create_filter_command(
			input		=> join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.gz'),
			tumour_ids	=> \@tumour_ids,
			normal_ids	=> \@normal_ids,
			output		=> $filtered_output
			);

		if ('Y' eq missing_file("$filtered_output.md5")) {

			# record command (in log directory) and then run job
			print $log "Submitting job for FILTER VARIANTS...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_filter_vcf_' . $patient,
				cmd	=> $filter_cmd,
				modules	=> ['perl', 'tabix'],
				dependencies	=> $apply_snp_recal_run_id,
				max_time	=> $parameters->{filter_recalibrated}->{time},
				mem		=> $parameters->{filter_recalibrated}->{mem},
				hpc_driver	=> $args{hpc_driver}
				);

			$filter_run_id = submit_job(
				jobname		=> 'run_filter_vcf_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $filter_run_id;
			}

		print $log "\nFINAL OUTPUT: $filtered_output.gz \n";
		print $log "---\n";
		}

	# collate results
	my $collect_output = join(' ',
		"Rscript $cwd/collect_germline_genotypes.R",
		'-d', $sample_directory,
		'-p', $tool_data->{project_name}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_germline_genotypes',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '8G',
		max_time	=> '12:00:00',
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'combine_germline_genotypes',
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

	# should intermediate files be removed?
	if ($args{del_intermediates}) {

		print $log "Submitting job to clean up temporary/intermediate files...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_cleanup_cohort',
			cmd	=> $cleanup_cmd,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver}
			);

		$run_id = submit_job(
			jobname		=> 'run_cleanup_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids => join(',', @all_jobs),
			outfile => $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver}
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		# wait until it finishes
		unless ($args{no_wait}) {

			my $complete = 0;
			my $timeouts = 0;

			while (!$complete && $timeouts < 20 ) {
				sleep(30);
				my $status = `sacct --format='State' -j $run_id`;

				# if final job has finished successfully:
				if ($status =~ m/COMPLETED/s) { $complete = 1; }
				# if we run into a server connection error (happens rarely with sacct)
				# increment timeouts (if we continue to repeatedly timeout, we will exit)
				elsif ($status =~ m/Connection timed out/) {
					$timeouts++;
					}
				# if the job is still pending or running, try again in a bit
				# but also reset timeouts, because we only care about consecutive timeouts
				elsif ($status =~ m/PENDING|RUNNING/) {
					$timeouts = 0;
					}
				# if none of the above, we will exit with an error
				else {
					die("Final GenotypeGVCFs accounting job: $run_id finished with errors.");
					}
				}
			}
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($data_config, $tool_config, $output_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $help, $no_wait);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	't|tool=s'	=> \$tool_config,
	'd|data=s'	=> \$data_config,
	'o|out_dir=s'	=> \$output_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry-run'	=> \$dry_run,
	'no-wait'	=> \$no_wait
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--cluster|-c\t<string> cluster scheduler (default: slurm)",
		"\t--remove\t<boolean> should intermediates be removed? (default: false)",
		"\t--dry-run\t<boolean> should jobs be submitted? (default: false)",
		"\t--no-wait\t<boolean> should we exit after job submission (true) or wait until all jobs have completed (false)? (default: false)"
		);

	print "$help_msg\n";
	exit;
	}

# do some quick error checks to confirm valid arguments	
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, data_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
