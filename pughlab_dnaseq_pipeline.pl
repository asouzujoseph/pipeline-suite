#!/usr/bin/env perl
### pughlab_dnaseq_pipeline.pl #####################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use POSIX qw(strftime);
use Getopt::Std;
use Getopt::Long;
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);
use List::Util qw(any);

my $cwd = dirname($0);
require "$cwd/scripts/utilities.pl";

####################################################################################################
# version       author	  	comment
# 1.0		sprokopec       script to run PughLab DNASeq pipeline

### USAGE ##########################################################################################
# pughlab_dnaseq_pipeline.pl -c tool_config.yaml -d data.yaml
#
# where:
#	- tool_config.yaml contains tool versions and parameters, output directory, reference
#	information, etc.
#	- data_config.yaml contains sample information (YAML file containing paths to FASTQ files,
#	generated by create_fastq_yaml.pl)

### SUBROUTINES ####################################################################################

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config	=> undef,
		data_config	=> undef,
		step1		=> undef,
		step2		=> undef,
		step3		=> undef,
		cleanup		=> undef,
		cluster		=> undef,
		dry_run		=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data = LoadFile($tool_config);
	my $date = strftime "%F", localtime;
	my $timestamp = strftime "%F_%H-%M-%S", localtime;

	# check for and/or create output directories
	my $output_directory = $tool_data->{output_dir};
	$output_directory =~ s/\/$//;
	my $log_directory = join('/', $output_directory, 'logs', 'run_DNA_pipeline_' . $timestamp);

	unless(-e $output_directory) { make_path($output_directory); }
	unless(-e $log_directory) { make_path($log_directory); }

	# start logging
	my $log_file = join('/', $log_directory, 'run_DNASeq_pipeline.log');
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";

	print $log "---\n";
	print $log "Running PughLab DNA-Seq pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n\n";

	my $seq_type = $tool_data->{seq_type};

	# indicate maximum time limit for parent jobs to wait
	my $max_time = '7-00:00:00';
	if ('wgs' eq $tool_data->{seq_type}) { $max_time = '21-00:00:00'; }

	### MAIN ###########################################################################################

	my $run_script;
	my ($bwa_run_id, $gatk_run_id, $contest_run_id, $coverage_run_id, $hc_run_id);
	my ($strelka_run_id, $mutect_run_id, $mutect2_run_id, $varscan_run_id);
	my ($somaticsniper_run_id, $delly_run_id, $vardict_run_id);
	my ($mavis_run_id, $report_run_id);

	my @job_ids;

	# prepare directory structure
	my $bwa_directory = join('/', $output_directory, 'BWA');
	my $gatk_directory = join('/', $output_directory, 'GATK');
	my $contest_directory = join('/', $output_directory, 'BAMQC', 'ContEst');
	my $coverage_directory = join('/', $output_directory, 'BAMQC', 'Coverage');
	my $hc_directory = join('/', $output_directory, 'HaplotypeCaller');
	my $strelka_directory = join('/', $output_directory, 'Strelka');
	my $mutect_directory = join('/', $output_directory, 'MuTect');
	my $mutect2_directory = join('/', $output_directory, 'MuTect2');
	my $varscan_directory = join('/', $output_directory, 'VarScan');
	my $vardict_directory = join('/', $output_directory, 'VarDict');
	my $somaticsniper_directory = join('/', $output_directory, 'SomaticSniper');
	my $delly_directory = join('/', $output_directory, 'Delly');
	my $mavis_directory = join('/', $output_directory, 'Mavis');

	# indicate YAML files for processed BAMs
	my $bwa_output_yaml = join('/', $bwa_directory, 'bwa_bam_config_' . $timestamp . '.yaml');
	my $gatk_output_yaml = join('/', $gatk_directory, 'gatk_bam_config_' . $timestamp . '.yaml');

	if ( (!$args{step1}) && ($args{step2}) ) {
		$gatk_output_yaml = $data_config;
		$gatk_run_id = '';
		}

	# Should pre-processing (alignment + GATK indel realignment/recalibration + QC) be performed?
	if ($args{step1}) {

		## run BWA-alignment pipeline
		unless(-e $bwa_directory) { make_path($bwa_directory); }

		if ('Y' eq $tool_data->{bwa}->{run}) {

			my $bwa_command = join(' ',
				"perl $cwd/scripts/bwa.pl",
				"-o", $bwa_directory,
				"-t", $tool_config,
				"-d", $data_config,
				"-b", $bwa_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$bwa_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for bwa.pl\n";
			print $log "  COMMAND: $bwa_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_bwa',
				cmd	=> $bwa_command,
				modules	=> ['perl'],
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$bwa_command .= " --dry-run";
				`$bwa_command`;

				} else {

				$bwa_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> BWA job id: $bwa_run_id\n\n";
				push @job_ids, $bwa_run_id;
				}
			}

		## run GATK indel realignment/recalibration pipeline
		unless(-e $gatk_directory) { make_path($gatk_directory); }

		if ('Y' eq $tool_data->{gatk}->{run}) {

			my $gatk_command = join(' ',
				"perl $cwd/scripts/gatk.pl",
				"-o", $gatk_directory,
				"-t", $tool_config,
				"-d", $bwa_output_yaml,
				"-c", $args{cluster},
				"-b", $gatk_output_yaml
				);

			if ($args{cleanup}) {
				$gatk_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for gatk.pl\n";
			print $log "  COMMAND: $gatk_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_gatk',
				cmd	=> $gatk_command,
				modules	=> ['perl'],
				dependencies	=> $bwa_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$gatk_command .= " --dry-run";
				`$gatk_command`;

				} else {

				$gatk_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> GATK job id: $gatk_run_id\n\n";
				push @job_ids, $gatk_run_id;
				}
			}

		## run GATK's ContEst for contamination estimation (T/N only)
		## and GATK's DepthOfCoverage and find Callable Bases
		unless(-e $contest_directory) { make_path($contest_directory); }
		unless(-e $coverage_directory) { make_path($coverage_directory); }

		if ('Y' eq $tool_data->{bamqc}->{run}) {

			my $contest_command = join(' ',
				"perl $cwd/scripts/contest.pl",
				"-o", $contest_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$contest_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for contest.pl\n";
			print $log "  COMMAND: $contest_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_contest',
				cmd	=> $contest_command,
				modules	=> ['perl'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$contest_command .= " --dry-run";
				`$contest_command`;

				} else {

				$contest_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> ContEst job id: $contest_run_id\n\n";
				push @job_ids, $contest_run_id;
				}

			my $coverage_command = join(' ',
				"perl $cwd/scripts/get_coverage.pl",
				"-o", $coverage_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$coverage_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for get_coverage.pl\n";
			print $log "  COMMAND: $coverage_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_coverage',
				cmd	=> $coverage_command,
				modules	=> ['perl'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$coverage_command .= " --dry-run";
				`$coverage_command`;

				} else {

				$coverage_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> Coverage job id: $coverage_run_id\n\n";
				push @job_ids, $coverage_run_id;
				}
			}
		}

	########################################################################################
	# From here on out, it makes more sense to run everything as a single batch.
	########################################################################################
	if ($args{step2}) {

		## run GATK's HaplotypeCaller pipeline
		if ('Y' eq $tool_data->{haplotype_caller}->{run}) {
	 
			$hc_run_id = '';
			my $hc_command = join(' ',
				"perl $cwd/scripts/haplotype_caller.pl",
				"-o", $hc_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$hc_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for haplotype_caller.pl\n";
			print $log "  COMMAND: $hc_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_haplotypecaller',
				cmd	=> $hc_command,
				modules	=> ['perl'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$hc_command .= " --dry-run";
				`$hc_command`;

				} else {

				$hc_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> HaplotypeCaller job id: $hc_run_id\n\n";
				push @job_ids, $hc_run_id;
				}

			# next step will run Genotype GVCFs, and filter final output
			$hc_command = join(' ',
				"perl $cwd/scripts/genotype_gvcfs.pl",
				"-o", $hc_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$hc_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for genotype_gvcfs.pl\n";
			print $log "  COMMAND: $hc_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_genotype_gvcfs',
				cmd	=> $hc_command,
				modules	=> ['perl'],
				dependencies	=> join(':', $gatk_run_id, $hc_run_id),
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);
		
			if ($args{dry_run}) {

				$hc_command .= " --dry-run";
				`$hc_command`;

				} else {

				$hc_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> GenotypeGVCFs job id: $hc_run_id\n\n";
				push @job_ids, $hc_run_id;
				}

			# finally, annotate and filter using CPSR/PCGR
			$hc_command = join(' ',
				"perl $cwd/scripts/annotate_germline.pl",
				"-o", $hc_directory,
				"-i", join('/', $hc_directory, 'cohort','germline_variants'),
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$hc_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for annotate_germline.pl\n";
			print $log "  COMMAND: $hc_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_annotate_germline',
				cmd	=> $hc_command,
				modules	=> ['perl'],
				dependencies	=> join(':', $gatk_run_id, $hc_run_id),
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);
		
			unless ($args{dry_run}) {

				$hc_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> AnnotateGermline job id: $hc_run_id\n\n";
				push @job_ids, $hc_run_id;
				}
			}

		## run STRELKA/MANTA pipeline
		if ('Y' eq $tool_data->{strelka}->{run}) {

			unless(-e $strelka_directory) { make_path($strelka_directory); }

			# first create a panel of normals
			my $pon = $tool_data->{strelka}->{pon};
			my $strelka_command;

			if (defined($tool_data->{strelka}->{pon})) {
				$strelka_run_id = '';
				} else {

				$pon = join('/', $strelka_directory, 'panel_of_normals.vcf');

				$strelka_command = join(' ',
					"perl $cwd/scripts/strelka.pl",
					"-o", $strelka_directory,
					"-t", $tool_config,
					"-d", $gatk_output_yaml,
					"--create-panel-of-normals",
					"-c", $args{cluster}
					);

				if ($args{cleanup}) {
					$strelka_command .= " --remove";
					}

				# record command (in log directory) and then run job
				print $log "Submitting job for strelka.pl --create-panel-of-normals\n";
				print $log "  COMMAND: $strelka_command\n\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'pughlab_dna_pipeline__run_strelka_pon',
					cmd	=> $strelka_command,
					modules	=> ['perl'],
					dependencies	=> $gatk_run_id,
					mem		=> '256M',
					max_time	=> $max_time,
					hpc_driver	=> $args{cluster}
					);

				if ($args{dry_run}) {

					$strelka_command .= " --dry-run";
					`$strelka_command`;

					} else {

					$strelka_run_id = submit_job(
						jobname		=> $log_directory,
						shell_command	=> $run_script,
						hpc_driver	=> $args{cluster},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);

					print $log ">>> Strelka PoN job id: $strelka_run_id\n\n";
					push @job_ids, $strelka_run_id;
					}
				}

			# next run somatic variant calling
			$strelka_command = join(' ',
				"perl $cwd/scripts/strelka.pl",
				"-o", $strelka_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster},
				"--pon", $pon
				);

			if ($args{cleanup}) {
				$strelka_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for strelka.pl\n";
			print $log "  COMMAND: $strelka_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_strelka',
				cmd	=> $strelka_command,
				modules	=> ['perl'],
				dependencies	=> join(':', $gatk_run_id, $strelka_run_id),
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$strelka_command .= " --dry-run";
				`$strelka_command`;

				} else {

				$strelka_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> Strelka job id: $strelka_run_id\n\n";
				push @job_ids, $strelka_run_id;
				}
			}

		## run GATK's MuTect pipeline
		if ('Y' eq $tool_data->{mutect}->{run}) {

			unless(-e $mutect_directory) { make_path($mutect_directory); }
 
			my $pon = $tool_data->{mutect}->{pon};
			my $mutect_command;

			if (defined($tool_data->{mutect}->{pon})) {
				$mutect_run_id = '';
				} else {
				$pon = join('/', $mutect_directory, 'panel_of_normals.vcf');

				# first create a panel of normals
				$mutect_command = join(' ',
					"perl $cwd/scripts/mutect.pl",
					"-o", join('/', $mutect_directory, 'PanelOfNormals'),
					"-t", $tool_config,
					"-d", $gatk_output_yaml,
					"-c", $args{cluster},
					"--create-panel-of-normals"
					);

				if ($args{cleanup}) {
					$mutect_command .= " --remove";
					}

				# record command (in log directory) and then run job
				print $log "Submitting job for mutect.pl --create-panel-of-normals\n";
				print $log "  COMMAND: $mutect_command\n\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'pughlab_dna_pipeline__run_mutect_pon',
					cmd	=> $mutect_command,
					modules	=> ['perl'],
					dependencies	=> $gatk_run_id,
					mem		=> '256M',
					max_time	=> $max_time,
					hpc_driver	=> $args{cluster}
					);

				if ($args{dry_run}) {

					$mutect_command .= " --dry-run";
					`$mutect_command`;

					} else {

					$mutect_run_id = submit_job(
						jobname		=> $log_directory,
						shell_command	=> $run_script,
						hpc_driver	=> $args{cluster},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);
				
					print $log ">>> MuTect PoN job id: $mutect_run_id\n\n";
					push @job_ids, $mutect_run_id;
					}
				}

			# next run somatic variant calling
			$mutect_command = join(' ',
				"perl $cwd/scripts/mutect.pl",
				"-o", $mutect_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster},
				"--pon", $pon
				);

			if ($args{cleanup}) {
				$mutect_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for mutect.pl\n";
			print $log "  COMMAND: $mutect_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_mutect',
				cmd	=> $mutect_command,
				modules	=> ['perl'],
				dependencies	=> join(':', $gatk_run_id, $mutect_run_id),
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$mutect_command .= " --dry-run";
				`$mutect_command`;

				} else {

				$mutect_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> MuTect job id: $mutect_run_id\n\n";
				push @job_ids, $mutect_run_id;
				}
			}

		## also run GATK's newer MuTect2 pipeline
		if ('Y' eq $tool_data->{mutect2}->{run}) {

			unless(-e $mutect2_directory) { make_path($mutect2_directory); }

			my $pon = $tool_data->{mutect2}->{pon};
			my $mutect2_command;

			if (defined($tool_data->{mutect2}->{pon})) {
				$mutect2_run_id = '';
				} else {
				$pon = join('/', $mutect2_directory, 'panel_of_normals.vcf');

				# first create a panel of normals
				$mutect2_command = join(' ',
					"perl $cwd/scripts/mutect2.pl",
					"-o", join('/', $mutect2_directory, 'PanelOfNormals'),
					"-t", $tool_config,
					"-d", $gatk_output_yaml,
					"-c", $args{cluster},
					"--create-panel-of-normals"
					);

				if ($args{cleanup}) {
					$mutect2_command .= " --remove";
					}

				# record command (in log directory) and then run job
				print $log "Submitting job for mutect2.pl --create-panel-of-normals\n";
				print $log "  COMMAND: $mutect2_command\n\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'pughlab_dna_pipeline__run_mutect2_pon',
					cmd	=> $mutect2_command,
					modules	=> ['perl'],
					dependencies	=> $gatk_run_id,
					mem		=> '256M',
					max_time	=> $max_time,
					hpc_driver	=> $args{cluster}
					);

				if ($args{dry_run}) {

					$mutect2_command .= " --dry-run";
					`$mutect2_command`;

					} else {

					$mutect2_run_id = submit_job(
						jobname		=> $log_directory,
						shell_command	=> $run_script,
						hpc_driver	=> $args{cluster},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);
				
					print $log ">>> MuTect2 PoN job id: $mutect2_run_id\n\n";
					push @job_ids, $mutect2_run_id;
					}
				}

			# now run the actual somatic variant calling
			$mutect2_command = join(' ',
				"perl $cwd/scripts/mutect2.pl",
				"-o", $mutect2_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster},
				"--pon", $pon
				);

			if ($args{cleanup}) {
				$mutect2_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for mutect2.pl\n";
			print $log "  COMMAND: $mutect2_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_mutect2',
				cmd	=> $mutect2_command,
				modules	=> ['perl'],
				dependencies	=> join(':', $gatk_run_id, $mutect2_run_id),
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$mutect2_command .= " --dry-run";
				`$mutect2_command`;

				} else {

				$mutect2_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> MuTect2 job id: $mutect2_run_id\n\n";
				push @job_ids, $mutect2_run_id;
				}
			}

		## run VarScan SNV/CNV pipeline
		if ('Y' eq $tool_data->{varscan}->{run}) {

			unless(-e $varscan_directory) { make_path($varscan_directory); }

			my $varscan_command = join(' ',
				"perl $cwd/scripts/varscan.pl",
				"-o", $varscan_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if (defined($tool_data->{varscan}->{pon})) {
				$varscan_command .= " --pon $tool_data->{varscan}->{pon}";
				}

			if ($args{cleanup}) {
				$varscan_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for varscan.pl\n";
			print $log "  COMMAND: $varscan_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_varscan',
				cmd	=> $varscan_command,
				modules	=> ['perl'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {
			
				$varscan_command .= " --dry-run";
				`$varscan_command`;

				} else {

				$varscan_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> VarScan job id: $varscan_run_id\n\n";
				push @job_ids, $varscan_run_id;
				}
			}

		## SomaticSniper pipeline
		if ('Y' eq $tool_data->{somaticsniper}->{run}) {

			unless(-e $somaticsniper_directory) { make_path($somaticsniper_directory); }

			my $somaticsniper_command = join(' ',
				"perl $cwd/scripts/somaticsniper.pl",
				"-o", $somaticsniper_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$somaticsniper_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for somaticsniper.pl\n";
			print $log "  COMMAND: $somaticsniper_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_somaticsniper',
				cmd	=> $somaticsniper_command,
				modules	=> ['perl'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$somaticsniper_command .= " --dry-run";
				`$somaticsniper_command`;

				} else {

				$somaticsniper_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> SomaticSniper job id: $somaticsniper_run_id\n\n";
				push @job_ids, $somaticsniper_run_id;
				}
			}

		## VarDict pipeline
		if ('Y' eq $tool_data->{vardict}->{run}) {

			unless(-e $vardict_directory) { make_path($vardict_directory); }

			my $vardict_command = "perl $cwd/scripts/vardict.pl";
			if ('wgs' eq $seq_type) { $vardict_command = "perl $cwd/scripts/vardict_wgs.pl"; }

			$vardict_command .= ' '. join(' ',
				"-o", $vardict_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$vardict_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for vardict.pl\n";
			print $log "  COMMAND: $vardict_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_vardict',
				cmd	=> $vardict_command,
				modules	=> ['perl'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$vardict_command .= " --dry-run";
				`$vardict_command`;

				} else {

				$vardict_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> VarDict job id: $vardict_run_id\n\n";
				push @job_ids, $vardict_run_id;
				}
			}

		## run Delly SV pipeline
		if ('Y' eq $tool_data->{delly}->{run}) {

			unless(-e $delly_directory) { make_path($delly_directory); }

			my $delly_command = join(' ',
				"perl $cwd/scripts/delly.pl",
				"-o", $delly_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$delly_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for delly.pl\n";
			print $log "  COMMAND: $delly_command\n\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_delly',
				cmd	=> $delly_command,
				modules	=> ['perl', 'samtools'],
				dependencies	=> $gatk_run_id,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			if ($args{dry_run}) {

				$delly_command .= " --dry-run";
				`$delly_command`;

				} else {

				$delly_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> Delly job id: $delly_run_id\n\n";
				push @job_ids, $delly_run_id;
				}
			}

		## run Mavis SV annotation pipeline
		if ('Y' eq $tool_data->{mavis}->{run}) {

			unless(-e $mavis_directory) { make_path($mavis_directory); }

			my $mavis_command = join(' ',
				"perl $cwd/scripts/mavis.pl",
				"-o", $mavis_directory,
				"-t", $tool_config,
				"-d", $gatk_output_yaml,
				"--manta", $strelka_directory,
				"--delly", $delly_directory,
				"-c", $args{cluster}
				);

			if ($args{cleanup}) {
				$mavis_command .= " --remove";
				}

			# record command (in log directory) and then run job
			print $log "Submitting job for mavis.pl\n";
			print $log "  COMMAND: $mavis_command\n\n";

			my $depends;
			if ( (defined($delly_run_id)) && (defined($strelka_run_id)) ) {
				$depends = join(':', $delly_run_id, $strelka_run_id);
				} elsif ( (defined($delly_run_id)) && !(defined($strelka_run_id)) ) {
				$depends = $delly_run_id;
				} elsif ( !(defined($delly_run_id)) && (defined($strelka_run_id)) ) {
				$depends = $strelka_run_id;
				}

			# because mavis.pl will search provided directories and run based on what it finds
			# (Manta/Delly resuts), this can only be run AFTER these respective jobs finish
			# so, we will submit this with dependencies
			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'pughlab_dna_pipeline__run_mavis',
				cmd	=> $mavis_command,
				modules	=> ['perl'],
				dependencies	=> $depends,
				mem		=> '256M',
				max_time	=> $max_time,
				hpc_driver	=> $args{cluster}
				);

			unless ($args{dry_run}) {

				$mavis_run_id = submit_job(
					jobname		=> $log_directory,
					shell_command	=> $run_script,
					hpc_driver	=> $args{cluster},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				print $log ">>> MAVIS job id: $mavis_run_id\n\n";
				push @job_ids, $mavis_run_id;
				}
			}
		}

	########################################################################################
	# Create a final report for the project.
	########################################################################################
	if ($args{step3}) {

		my $report_command = join(' ',
			"perl $cwd/scripts/pughlab_pipeline_auto_report.pl",
			"-t", $tool_config,
			"-c", $args{cluster},
			"-d", $date
			);

		# record command (in log directory) and then run job
		print $log "Submitting job for pughlab_pipeline_auto_report.pl\n";
		print $log "  COMMAND: $report_command\n\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'pughlab_dna_pipeline__run_report',
			cmd	=> $report_command,
			modules	=> ['perl'],
			dependencies	=> join(':', @job_ids),
			mem		=> '256M',
			max_time	=> '5-00:00:00',
			hpc_driver	=> $args{cluster}
			);

		unless ($args{dry_run}) {

			$report_run_id = submit_job(
				jobname		=> $log_directory,
				shell_command	=> $run_script,
				hpc_driver	=> $args{cluster},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			print $log ">>> Report job id: $report_run_id\n\n";
			}
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;

	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($tool_config, $data_config);
my ($preprocessing, $variant_calling, $create_report);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run);
my $help;

# read in command line arguments
GetOptions(
	'h|help'		=> \$help,
	't|tool=s'		=> \$tool_config,
	'd|data=s'		=> \$data_config,
	'preprocessing'		=> \$preprocessing,
	'variant_calling'	=> \$variant_calling,
	'create_report'		=> \$create_report,
	'c|cluster=s'		=> \$hpc_driver,
	'remove'		=> \$remove_junk,
	'dry-run'		=> \$dry_run
	 );

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--preprocessing\t<boolean> should data pre-processing be performed? (default: false)",
		"\t--variant_calling\t<boolean> should variant calling be performed? (default: false)",
		"\t--create_report\t<boolean> should a report be generated? (default: false)",
		"\t--cluster|-c\t<string> cluster scheduler (default: slurm)",
		"\t--remove\t<boolean> should intermediates be removed? (default: false)",
		"\t--dry-run\t<boolean> should jobs be submitted? (default: false)"
		);

	print "$help_msg\n";
	exit;
	}

if ( (!$preprocessing) && (!$variant_calling) ) {
	die("Please choose a step to run (either --preprocessing and/or --variant_caling)");
	}
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }

# check for compatible HPC driver; if not found, change dry_run to Y
my @compatible_drivers = qw(slurm);
if ( (!any { /$hpc_driver/ } @compatible_drivers ) && (!$dry_run) ) {
	print "Unrecognized HPC driver requested: setting dry_run to true -- jobs will not be submitted but commands will be written to file.\n";
	$dry_run = 1;
	}

main(
	tool_config	=> $tool_config,
	data_config	=> $data_config,
	step1		=> $preprocessing,
	step2		=> $variant_calling,
	step3		=> $create_report,
	cluster		=> $hpc_driver,
	cleanup		=> $remove_junk,
	dry_run		=> $dry_run
	);
