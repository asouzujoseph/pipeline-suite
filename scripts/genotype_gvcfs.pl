#!/usr/bin/env perl
### filter_germline_variants.pl ####################################################################
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

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $known_1000g, $hapmap, $omni, $known_mills, $dbsnp);

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to filter germline/somatic SNVs/INDELs from haplotypecaller

### USAGE ##########################################################################################
# filter_germline_variants.pl -d data_config.yaml
#
# where:
# 	- data_config.yaml contains sample information (YAML file containing paths to fastq
# 	generated by create_Fastq_yaml.pl)

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
		$vqsr_command .= join(' ',
			'-resource:mills,known=true,training=true,truth=true,prior=12.0', $known_mills,
			'-an DP -an FS -an MQRankSum -an ReadPosRankSum -mode INDEL',
			'-tranche 100.0 -tranche 99.9 -tranche 99.0 -tranche 90.0 --maxGaussians 2'
			);

		} elsif ('SNP' eq $args{var_type}) {

		$vqsr_command .= join(' ',
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

### MAIN ###########################################################################################
sub main{
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		dependencies		=> '',
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'gatk');
	my $date = strftime "%F", localtime;

	# deal with extra arguments
	$tool_data->{HPC_driver} = $args{hpc_driver};
	$tool_data->{del_intermediates} = $args{del_intermediates};
	$tool_data->{dry_run} = $args{dry_run};

	# organize output directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_GENOTYPEGVCFs_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	if ('N' eq $tool_data->{dry_run}) {
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
	my $gatk = 'gatk/' . $tool_data->{tool_version};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $cleanup_cmd);
	my @all_jobs;

	# set up some directories
	my $cohort_directory = join('/', $output_directory, '../cohort');
	unless (-e $cohort_directory) { make_path($cohort_directory); }

	my $tmp_directory = join('/', $cohort_directory, 'TEMP');
	unless (-e $tmp_directory) { make_path($tmp_directory); }

	my $sample_directory = join('/', $cohort_directory, 'germline_variants');
	unless (-e $sample_directory) { make_path($sample_directory); }

	# First step, find all of the CombineGVCF files
	opendir(HC_OUTPUT, $output_directory) or die "Could not open $output_directory";
	my @combined_gvcfs = grep { /'g.vcf.gz\$'/ } readdir(HC_OUTPUT);
	closedir(HC_OUTPUT);

	my $genotype_run_id = '';
	my $genotype_cmd = create_genotype_gvcfs_command(
		input		=> join(' -V ', @combined_gvcfs),
		output		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $tool_data->{parameters}->{genotype_gvcfs}->{java_mem}
		);

	$genotype_cmd .= join(' ',
		"\n\nmd5sum", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		">", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.md5'),
		"\n\nbgzip", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		"\ntabix -p vcf", join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz')
		);

	$cleanup_cmd = 'rm ' . join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.gz');

	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf.md5'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for GenotypeGVCFs...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_genotype_gvcfs_cohort',
			cmd	=> $genotype_cmd,
			modules	=> [$gatk, 'tabix'],
			dependencies	=> $args{dependencies},
			max_time	=> $tool_data->{parameters}->{genotype_gvcfs}->{time},
			mem		=> $tool_data->{parameters}->{genotype_gvcfs}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$genotype_run_id = submit_job(
			jobname		=> 'run_genotype_gvcfs_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $genotype_run_id;
		}

	# Now run VQSR on INDELs
	my $vqsr_indel_run_id = '';
	my $vqsr_cmd_indel = create_vqsr_command(
		var_type	=> 'INDEL',
		input		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		output_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $tool_data->{parameters}->{vqsr}->{java_mem}
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
			max_time	=> $tool_data->{parameters}->{vqsr}->{time},
			mem		=> $tool_data->{parameters}->{vqsr}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$vqsr_indel_run_id = submit_job(
			jobname		=> 'run_vqsr_indels_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $vqsr_indel_run_id;
		}

	# And finally, apply these recalibrations
	my $apply_indel_recal_run_id = '';
	my $apply_vqsr_indel = create_apply_vqsr_command(
		var_type	=> 'INDEL',
		input		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		vqsr_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_indel'),
		output		=> join('/', $cohort_directory, 'haplotype_caller_indel_recalibrated.vcf'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $tool_data->{parameters}->{apply_vqsr}->{java_mem}
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
			cmd	=> $vqsr_cmd_indel,
			modules	=> [$gatk],
			dependencies	=> $vqsr_indel_run_id,
			max_time	=> $tool_data->{parameters}->{apply_vqsr}->{time},
			mem		=> $tool_data->{parameters}->{apply_vqsr}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$apply_indel_recal_run_id = submit_job(
			jobname		=> 'run_apply_indel_recalibration_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $apply_indel_recal_run_id;
		}

	# Now run VQSR on SNPs
	my $vqsr_snp_run_id = '';
	my $vqsr_cmd_snp = create_vqsr_command(
		var_type	=> 'SNP',
		input		=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes.g.vcf'),
		output_stem	=> join('/', $cohort_directory, 'haplotype_caller_combined_genotypes_snp'),
		tmp_dir		=> $tmp_directory,
		java_mem	=> $tool_data->{parameters}->{vqsr}->{java_mem}
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
			max_time	=> $tool_data->{parameters}->{vqsr}->{time},
			mem		=> $tool_data->{parameters}->{vqsr}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$vqsr_snp_run_id = submit_job(
			jobname		=> 'run_vqsr_snps_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
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
		java_mem	=> $tool_data->{parameters}->{apply_vqsr}->{java_mem}
		);

	$apply_vqsr_snp .= join(' ',
		"\n\nmd5sum", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf'),
		">", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.md5'),
		"\n\nbgzip", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf'),
		"\ntabix -p vcf", join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.gz')
		);

#	$cleanup_cmd .= "\nrm " . join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.gz');
 
	if ('Y' eq missing_file(join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.md5'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for SNP recalibration...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_apply_snp_recalibration_cohort',
			cmd	=> $apply_vqsr_snp,
			modules	=> [$gatk, 'tabix'],
			dependencies	=> join(',', $apply_indel_recal_run_id, $vqsr_snp_run_id),
			max_time	=> $tool_data->{parameters}->{apply_vqsr}->{time},
			mem		=> $tool_data->{parameters}->{apply_vqsr}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$apply_snp_recal_run_id = submit_job(
			jobname		=> 'run_apply_snp_recalibration_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $apply_snp_recal_run_id;
		}

	# process each sample in $smp_data
	my ($filter_cmd, $filter_run_id) = '';
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		my @tumour_ids = keys %{$smp_data->{$patient}->{tumour}};
		my @normal_ids = keys %{$smp_data->{$patient}->{normal}};

		if (scalar(@normal_ids) > 0) {
			$filter_cmd = join(' ',
				"perl $cwd/filter_germline_variants.pl",
				'--vcf', join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.gz'),
				'--tumour', join(',', @tumour_ids),
				'--normal', join(',', @normal_ids),
				'--output-stem', join('/', $sample_directory, $patient),
				'--reference', $reference
				);

			$filter_cmd .= join(' ',
				"\n\nmd5sum", join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf'),
				">", join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf.md5'),
				"\n\nbgzip", join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf'),
				"\ntabix -p vcf", join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf.gz')
				);

			} elsif (scalar(@normal_ids) == 0) {

			$filter_cmd = join(' ',
				"perl $cwd/filter_germline_variants.pl",
				'--vcf', join('/', $cohort_directory, 'haplotype_caller_genotypes_recalibrated.vcf.gz'),
				'--tumour', join(',', @tumour_ids),
				'--output-stem', join('/', $sample_directory, $patient),
				'--reference', $reference
				);

			$filter_cmd .= join(' ',
				"\n\nmd5sum", join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf'),
				">", join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf.md5'),
				"\n\nbgzip", join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf'),
				"\ntabix -p vcf", join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf.gz')
				);
			}

		if (
			('Y' eq missing_file(join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf.md5'))) ||
			('Y' eq missing_file(join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf.md5')))
			) {

			# record command (in log directory) and then run job
			print $log "Submitting job for FILTER VARIANTS...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_filter_vcf_' . $patient,
				cmd	=> $filter_cmd,
				modules	=> ['perl', 'tabix'],
				dependencies	=> $apply_snp_recal_run_id,
				max_time	=> $tool_data->{parameters}->{filter}->{time},
				mem		=> $tool_data->{parameters}->{filter}->{mem},
				hpc_driver	=> $tool_data->{HPC_driver}
				);

			$filter_run_id = submit_job(
				jobname		=> 'run_filter_vcf_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $tool_data->{HPC_driver},
				dry_run		=> $tool_data->{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $filter_run_id;
			}

		if ( scalar(@normal_ids) == 0) {
			print $log "\nFINAL OUTPUT: " .	join('/', $sample_directory, $patient . '_filtered_hc_variants.vcf.gz') . "\n";
			} else {
			print $log "\nFINAL OUTPUT: " . join('/', $sample_directory, $patient . '_filtered_germline_variants.vcf.gz') . "\n";
			}

		print $log "---\n";
		}

	# should intermediate files be removed?
	my $run_id;
	if ('Y' eq $tool_data->{del_intermediates}) {

		print $log "Submitting job to clean up temporary/intermediate files...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_cleanup_cohort',
			cmd	=> $cleanup_cmd,
			dependencies	=> join(',', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'run_cleanup_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);
		}

	# collect job metrics if not dry_run
	if ('N' eq $tool_data->{dry_run}) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids => join(',', @all_jobs),
			outfile => $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(',', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($data_config, $tool_config, $output_directory);
my $hpc_driver = 'slurm';
my $remove_junk = 'N';
my $dry_run = 'Y';
my $dependencies = '';

# get command line arguments
GetOptions(
	't|tool=s'	=> \$tool_config,
	'd|data=s'	=> \$data_config,
	'o|out_dir=s'	=> \$output_directory,
        'h|hpc=s'	=> \$hpc_driver,
        'r|remove=s'	=> \$remove_junk,
        'n|dry_run=s'	=> \$dry_run,
	'depends=s'	=> \$dependencies
	);

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
	dependencies		=> $dependencies
	);
