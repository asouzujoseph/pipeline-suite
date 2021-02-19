#!/usr/bin/env perl
### delly.pl ######################################################################################
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
use List::Util qw(any first);
use IO::Handle;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $exclude_regions) = undef;

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to run Delly SV caller
# 1.1		sprokopec	added help msg and cleaned up code
# 1.2		sprokopec	minor updates for tool config

### USAGE ##########################################################################################
# delly.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run
#
# where:
#	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
#		GATK-processed BAMs, generated by gatk.pl)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	-c indicates hpc driver (ie, slurm)
#	--remove indicates that intermediates will be removed
#	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to run Manta
sub get_delly_command {
	my %args = (
		tumour	=> undef,
		normal	=> undef,
		output	=> undef,
		@_
		);

	my $delly_cmd = join(' ',
		'delly call',
		'-g', $reference,
		'-x', $exclude_regions,
		'-o', $args{output}
		);

	if (defined($args{tumour})) {
		$delly_cmd .= ' ' . $args{tumour};
		}

	if (defined($args{normal})) {
		$delly_cmd .= ' ' . $args{normal};
		}

	return($delly_cmd);
	}

# format command to merge multiple samples (Delly function)
sub get_delly_merge_command {
	my %args = (
		input	=> undef,
		output	=> undef,
		type	=> undef,
		@_
		);

	my $merge_command = 'export LC_ALL=C';

	if ('germline' eq $args{type}) {
		$merge_command .= "\n\n". join(' ',
			'delly merge',
			'-o', $args{output},
			$args{input}
			);
		}

	elsif ('somatic' eq $args{type}) {
		$merge_command .= "\n\n" . join(' ',
			'delly merge',
			'-o', $args{output},
			'-m 0 -n 250000000 -b 0 -r 1.0',
			$args{input}
			);
		}

	return($merge_command);
	}

# format command to genotype samples at given sites
sub get_delly_genotype_command {
	my %args = (
		input	=> undef,
		sites	=> undef,
		output	=> undef,
		@_
		);

	my $genotype_command = join(' ',
		'delly call',
		'-g', $reference,
		'-x', $exclude_regions,
		'-v', $args{sites},
		'-o', $args{output},
		$args{input}
		);

	return($genotype_command);
	}

# format command to filter SV calls
sub get_delly_filter_command {
	my %args = (
		input	=> undef,
		output	=> undef,
		type	=> undef,
		samples	=> undef,
		@_
		);

	my $filter_command;

	if ('germline' eq $args{type}) {

		$filter_command = join(' ',
			'delly filter',
			'-f germline -p',
			'-o', $args{output},
			$args{input}
			);
		}

	elsif ('somatic' eq $args{type}) {

		$filter_command = join(' ',
			'delly filter',
			'-f somatic',
			'-o', $args{output},
			'-s', $args{samples},
			'-m 0 -a 0.1 -r 0.5 -v 10 -p',
			$args{input}
			);
		}

	return($filter_command);
	}

# format command to generate PON
sub generate_pon {
	my %args = (
		input		=> undef,
		intermediate	=> undef,
		output		=> undef,
		@_
		);

	my $pon_command = join(' ',
		'bcftools merge',
		'-m id -O b',
		'-o', $args{intermediate},
		$args{input}
		);

	$pon_command .= "\n\n" . join(' ',
		'bcftools index',
		'--csi',
		$args{intermediate}
		);

	$pon_command .= "\n\n" . get_delly_filter_command(
		output	=> $args{output},
		input	=> $args{intermediate},
		type	=> 'germline'
		);

	return($pon_command);
	}

# format command to merge genotyped bcfs
sub merge_genotyped_bcfs {
	my %args = (
		input		=> undef,
		output		=> undef,
		@_
		);

	my $job_command = join(' ',
		'bcftools merge',
		'-O b --force-samples',
		'-o', $args{output},
		$args{input}
		);

	$job_command .= "\n\n" . join(' ',
		'bcftools index',
		'--csi',
		$args{output}
		);

	return($job_command);
	}

# format command to finalize sv calls
sub get_finalize_command {
	my %args = (
		id		=> undef,
		input		=> undef,
		output		=> undef,
		@_
		);

	my @id_parts = split /\t/, $args{id};
	my $sm_tag = $id_parts[0];
	my $tumour_id = $id_parts[2];
	chomp($tumour_id);

	my $job_command;

	if ($sm_tag eq $tumour_id) {

		$job_command = join(' ',
			'bcftools view',
			'-s', $tumour_id,
			'-O v -o', $args{output},
			$args{input}
			);

		} else {

		$job_command = "echo $sm_tag $tumour_id > $args{output}.reheader";
		$job_command .= "\n\n" . join(' ',
			'bcftools view',
			'-s', $sm_tag,
			$args{input},
			'| bcftools reheader',
			'-s', "$args{output}.reheader",
			'>', $args{output}
			);

		$job_command .= "\n\nrm $args{output}.reheader";
		}

	return($job_command);
	}

# function to extract SM tag from BAM header
sub get_sm_tag {
	my %args = (
		bam => undef,
		@_
		);

	# read in bam header (RG tags only)
	open (my $bam_fh, "samtools view -H $args{bam} | grep '^\@RG' |");
	# only look at first line
	my $line = <$bam_fh>;
	close($bam_fh);
	chomp($line);

	my @header_parts = split(/\t/, $line);
	# pull out and clean SM tag
	my $sm_tag = first { $_ =~ m/SM:/ } @header_parts;
	$sm_tag =~ s/^SM://;

	return($sm_tag);
	}

### PANEL OF NORMALS ###############################################################################
sub pon {
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
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'delly');
	my $date = strftime "%F", localtime;

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_DELLY_germline_SV_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	unless ($args{dry_run}) {
		# initiate a file to hold job metrics
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_DELLY_germline_SV_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Delly (germline) SV calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	if ( ('hg38' eq $tool_data->{ref_type}) || ('GRCh38' eq $tool_data->{ref_type}) ) {
		$exclude_regions = '/cluster/projects/pughlab/references/Delly/excludeTemplates/human.hg38.excl.tsv';
		} elsif ( ('hg19' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type}) ) {
		$exclude_regions = '/cluster/projects/pughlab/references/Delly/excludeTemplates/human.hg19.excl.tsv';
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $delly	= 'delly/' . $tool_data->{delly_version};
	my $samtools 	= 'samtools/' . $tool_data->{samtools_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{delly}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link);
	my (@part1_jobs, @part2_jobs, @all_jobs);
	my (@pon_bcfs, @genotyped_bcfs);

	# create some directories
	my $link_directory = join('/', $output_directory, 'bam_links');
	unless(-e $link_directory) { make_path($link_directory); }

	my $intermediate_directory = join('/', $output_directory, 'intermediate_files');
	unless(-e $intermediate_directory) { make_path($intermediate_directory); }

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		if (scalar(@normal_ids) == 0) {
			print $log "\n>> No normal BAM provided, skipping patient.\n";
			next;
			}

		# for germline variants
		foreach my $norm (@normal_ids) {

			print $log ">>NORMAL: $norm\n";

			# create some symlinks
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$norm};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$norm}, $link);

			$run_id = '';

			# run germline snv caller
			my $germline_output = join('/', $intermediate_directory, $norm . '_Delly_SV.bcf');

			my $germline_command = get_delly_command(
				normal		=> $smp_data->{$patient}->{normal}->{$norm},
				output		=> $germline_output
				);

			$germline_command .= "\n\n" . "md5sum $germline_output > $germline_output.md5";

			# check if this should be run
			if ('Y' eq missing_file($germline_output . ".md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Delly (germline)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_delly_germline_' . $norm,
					cmd	=> $germline_command,
					modules	=> [$delly],
					max_time	=> $parameters->{call}->{time},
					mem		=> $parameters->{call}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_delly_germline_' . $norm,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @part1_jobs, $run_id;
				}
			else {
				print $log "Skipping Delly (germline) because this has already been completed!\n";
				}

			push @pon_bcfs, $germline_output;
			}
		}

	push @all_jobs, @part1_jobs;

	# should the panel of normals be created?
	my $pon_run_id = '';

	print $log "\n\nMerging called sites...\n";

	# let's create a command and write script to combine variants for a PoN
	my $pon_sites = join('/', $output_directory, $date . "_merged_panelOfNormals.bcf");
	my $pon_merged = join('/', $output_directory, $date . "_merged_genotyped_PoN.bcf");
	my $pon_genotyped = join('/', $output_directory, $date . "_merged_genotyped_filtered_PoN.bcf");
	my $final_pon_link = join('/', $output_directory, '..', 'panelOfNormals.bcf');

	if (-l $final_pon_link) {
		unlink $final_pon_link or die "Failed to remove previous symlink: $final_pon_link";
		}

	symlink($pon_genotyped, $final_pon_link);

	# merge all sites across all samples
	my $pon_command = get_delly_merge_command(
		input	=> join(' ', @pon_bcfs),
		output	=> $pon_sites,
		type	=> 'germline'
		);

	if ('Y' eq missing_file($pon_sites)) {

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'merge_called_sites_PoN',
			cmd	=> $pon_command,
			modules	=> [$delly],
			dependencies	=> join(':', @part1_jobs),
			max_time	=> $parameters->{merge}->{time},
			mem		=> $parameters->{merge}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$pon_run_id = submit_job(
			jobname		=> 'merge_called_sites_PoN',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $pon_run_id;
		}

	# genotype these sites for each sample
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		next if (scalar(@normal_ids) == 0);

		# for germline variants
		foreach my $norm (@normal_ids) {

			print $log ">>NORMAL: $norm\n";

			$run_id = '';

			# run delly genotype on called sites
			my $genotype_output = join('/', $intermediate_directory, $norm . '_Delly_SV_genotyped.bcf');

			my $genotype_command = get_delly_genotype_command(
				input		=> $smp_data->{$patient}->{normal}->{$norm},
				output		=> $genotype_output,
				sites		=> $pon_sites
				);

			$genotype_command .= "\n\n" . "md5sum $genotype_output > $genotype_output.md5";

			# check if this should be run
			if ('Y' eq missing_file($genotype_output . ".md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Delly Genotype (germline)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_delly_genotype_germline_' . $norm,
					cmd	=> $genotype_command,
					modules	=> [$delly],
					dependencies	=> $pon_run_id,
					max_time	=> $parameters->{genotype}->{time},
					mem		=> $parameters->{genotype}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_delly_genotype_germline_' . $norm,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @part2_jobs, $run_id;
				}
			else {
				print $log "Skipping Delly Genotype (germline) because this has already been completed!\n";
				}

			push @genotyped_bcfs, $genotype_output;
			}
		}

	push @all_jobs, @part2_jobs;

	# merge these genotyped results and filter only germline
	$pon_command = generate_pon(
		input		=> join(' ', @genotyped_bcfs),
		intermediate	=> $pon_merged,
		output		=> $pon_genotyped
		);

	$pon_command .= "\n\n" . "md5sum $pon_merged > $pon_merged.md5";
	$pon_command .= "\n\n" . "md5sum $pon_genotyped > $pon_genotyped.md5";

	if ('Y' eq missing_file($pon_genotyped . ".md5")) {

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'create_panel_of_normals',
			cmd	=> $pon_command,
			dependencies	=> join(':', @part2_jobs),
			modules		=> [$delly, $samtools],
			max_time	=> $parameters->{filter}->{time},
			mem		=> $parameters->{filter}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$run_id = submit_job(
			jobname		=> 'create_panel_of_normals',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;
		}

	# should intermediate files be removed
	if ($args{del_intermediates}) {

		print $log "\nSubmitting job to clean up temporary/intermediate files...\n";

		# make sure final output exists before removing intermediate files!
		my $cleanup_cmd = join("\n",
			"if [ -s $pon_genotyped.md5 ]; then",
			"  rm $intermediate_directory/*Delly_SV.bcf",
			"  rm $intermediate_directory/*Delly_SV_genotyped.bcf",
			"else",
			'  echo "FINAL OUTPUT is missing; not removing intermediates"',
			"fi"
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_pon_cleanup',
			cmd	=> $cleanup_cmd,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0
			);

		$run_id = submit_job(
			jobname		=> 'run_pon_cleanup',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);
		}

	print $log "\nFINAL OUTPUT: $pon_genotyped\n";
	print $log "---\n";

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0
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
					die("Final DELLY accounting job: $run_id finished with errors.");
					}
				}
			}
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### MAIN ###########################################################################################
sub main {
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
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'delly');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_DELLY_somatic_SV_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	unless ($args{dry_run}) {
		# initiate a file to hold job metrics
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_DELLY_somatic_SV_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";

	print $log "---\n";
	print $log "Running Delly (somatic) SV calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	if ( ('hg38' eq $tool_data->{ref_type}) || ('GRCh38' eq $tool_data->{ref_type}) ) {
		$exclude_regions = '/cluster/projects/pughlab/references/Delly/excludeTemplates/human.hg38.excl.tsv';
		} elsif ( ('hg19' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type}) ) {
		$exclude_regions = '/cluster/projects/pughlab/references/Delly/excludeTemplates/human.hg19.excl.tsv';
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $delly	= 'delly/' . $tool_data->{delly_version};
	my $samtools 	= 'samtools/' . $tool_data->{samtools_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{delly}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link);
	my (@part1_jobs, @part2_jobs, @all_jobs);
	my (@normal_sample_ids, @filtered_bcfs, @genotyped_bcfs);

	my %sample_sheet_tumour;
	my @sample_sheet_normal;
	my (%final_outputs, %patient_jobs, %cleanup);

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = sort keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = sort keys %{$smp_data->{$patient}->{'tumour'}};

		push @normal_sample_ids, @normal_ids;

		if (scalar(@tumour_ids) == 0) {
			print $log "\n>> No tumour BAM provided, skipping patient.\n";
			next;
			}

		@patient_jobs{$patient} = [];
		@final_outputs{$patient} = [];
		$cleanup{$patient} = '';

		@sample_sheet_tumour{$patient} = [];

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# generate necessary samples.tsv
		my $sample_sheet = join('/', $patient_directory, 'sample_sheet.tsv');
		open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

		# create some symlinks and add samples to sheet
		my (@tumour_bams, @normal_bams);

		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);

			my $sm_tag = get_sm_tag(bam => $smp_data->{$patient}->{normal}->{$normal});

			print $fh "$sm_tag\tcontrol\t$normal\n";
			push @normal_bams, $smp_data->{$patient}->{normal}->{$normal};
			push @sample_sheet_normal, "$sm_tag\tcontrol\t$normal\n";
			}
		foreach my $tumour (@tumour_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);

			my $sm_tag = get_sm_tag(bam => $smp_data->{$patient}->{tumour}->{$tumour});

			print $fh "$sm_tag\ttumor\t$tumour\n";
			push @tumour_bams, $smp_data->{$patient}->{tumour}->{$tumour};
			push @{$sample_sheet_tumour{$tumour}}, "$sm_tag\ttumor\t$tumour\n";
			}

		close $fh;

		$run_id = '';

		my $delly_cmd;
		my $delly_output = join('/', $patient_directory, $patient . '_Delly_SVs.bcf');

		# run on tumour-only
		if (scalar(@normal_ids) == 0) {

			$delly_cmd = get_delly_command(
				tumour	=> join(' ', @tumour_bams),
				output	=> $delly_output
				);

			push @filtered_bcfs, $delly_output;

			} else { # run on T/N pairs

			$delly_cmd = get_delly_command(
				tumour	=> join(' ', @tumour_bams),
				normal	=> join(' ', @normal_bams),
				output	=> $delly_output
				);
			}

		$delly_cmd .= "\n\n" . "md5sum $delly_output > $delly_output.md5";

		$cleanup{$patient} .= "rm $delly_output\n";

		# check if this should be run
		if ('Y' eq missing_file($delly_output . ".md5")) {

			# record command (in log directory) and then run job
			print $log "Submitting job for Delly Call SV...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_delly_somatic_SV_caller_' . $patient,
				cmd	=> $delly_cmd,
				modules	=> [$delly],
				max_time	=> $parameters->{call}->{time},
				mem		=> $parameters->{call}->{mem},
				hpc_driver	=> $args{hpc_driver}
				);

			$run_id = submit_job(
				jobname		=> 'run_delly_somatic_SV_caller_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @part1_jobs, $run_id;
			push @{$patient_jobs{$patient}}, $run_id;
			}
		else {
			print $log "Skipping Delly (somatic) because this has already been completed!\n";
			}

		# filter calls (only possible if a normal was provided)
		if (scalar(@normal_ids) > 0) {

			my $filter_output = join('/', $patient_directory, $patient . '_Delly_SVs_somatic.bcf');

			my $filter_cmd = get_delly_filter_command(
				input	=> $delly_output,
				output	=> $filter_output,
				type	=> 'somatic',
				samples	=> $sample_sheet
				);

			$filter_cmd .= "\n\n" . "md5sum $filter_output > $filter_output.md5";

			$cleanup{$patient} .= "rm $filter_output\n";

			# check if this should be run
			if ('Y' eq missing_file($filter_output . ".md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Delly filter...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_delly_somatic_filter_' . $patient,
					cmd	=> $filter_cmd,
					modules	=> [$delly],
					dependencies	=> $run_id,
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_delly_somatic_filter_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @part1_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				}
			else {
				print $log "Skipping Delly filter (somatic) because this has already been completed!\n";
				}

			push @filtered_bcfs, $filter_output;
			}
		}

	push @all_jobs, @part1_jobs;

	print $log "\nMerging candidate somatic SVs across all samples...\n\n";

	# merge filtered output to get a somatic SV site list
	my $merged_output = join('/', $output_directory, 'candidateSVs_merged.bcf');

	my $merge_cmd = get_delly_merge_command(
		input	=> join(' ', @filtered_bcfs),
		output	=> $merged_output,
		type	=> 'somatic'
		);

	$merge_cmd .= "\n\n" . "md5sum $merged_output > $merged_output.md5";

	# check if this should be run
	my $merge_run_id = '';

	if ('Y' eq missing_file($merged_output . ".md5")) {

		# record command (in log directory) and then run job
		print $log "Submitting job for Delly merge...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_delly_merge_somatic_candidateSVs',
			cmd	=> $merge_cmd,
			modules	=> [$delly],
			dependencies	=> join(':', @part1_jobs),
			max_time	=> $parameters->{merge}->{time},
			mem		=> $parameters->{merge}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$merge_run_id = submit_job(
			jobname		=> 'run_delly_merge_somatic_candidateSVs',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $merge_run_id;
		}
	else {
		print $log "Skipping Delly merge (somatic) because this has already been completed!\n";
		}

	print $log "\nGenotyping candidate somatic SVs across all samples...\n\n";

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = sort keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = sort keys %{$smp_data->{$patient}->{'tumour'}};

		next if (scalar(@tumour_ids) == 0);

		my @sample_ids = @tumour_ids;
		push @sample_ids, @normal_ids;

		my $patient_directory = join('/', $output_directory, $patient);

		# for each tumour sample
		foreach my $sample (@sample_ids) {

			print $log ">>SAMPLE: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $type = 'normal';

			# if this is a tumour sample
			if (any { $_ =~ m/$sample/ } @tumour_ids) {

				$type = 'tumour';

				# generate necessary samples.tsv
				my $sample_sheet = join('/', $sample_directory, 'sample_sheet.tsv');
				open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

				print $fh @{$sample_sheet_tumour{$sample}};

				foreach my $i ( @sample_sheet_normal ) {
					print $fh $i;
					}

				close $fh;
				}

			# run delly genotype on called sites
			my $genotype_output = join('/', $sample_directory, $sample . '_Delly_SVs_genotyped.bcf');

			my $genotype_command = get_delly_genotype_command(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output		=> $genotype_output,
				sites		=> $merged_output
				);

			$genotype_command .= "\n\n" . "md5sum $genotype_output > $genotype_output.md5";

			$cleanup{$patient} .= "rm $genotype_output\n";

			# check if this should be run
			if ('Y' eq missing_file($genotype_output . ".md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Delly Genotype (somatic)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_delly_genotype_somatic_' . $sample,
					cmd	=> $genotype_command,
					modules	=> [$delly],
					dependencies	=> $merge_run_id,
					max_time	=> $parameters->{genotype}->{time},
					mem		=> $parameters->{genotype}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_delly_genotype_somatic_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @part2_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				}
			else {
				print $log "Skipping Delly Genotype (somatic) because this has already been completed!\n";
				}

			push @genotyped_bcfs, $genotype_output;
			}
		}

	push @all_jobs, @part2_jobs;

	print $log "\nMerging genotyped somatic SVs across all samples...\n\n";

	# merge these genotyped results and filter only somatic
	my $merged_somatic_output = join('/', $output_directory, 'somatic_genotyped_SVs_merged.bcf');

	my $merge_somatic_svs = merge_genotyped_bcfs(
		input		=> join(' ', @genotyped_bcfs),
		output		=> $merged_somatic_output
		);

	$merge_somatic_svs .= "\n\n" . "md5sum $merged_somatic_output > $merged_somatic_output.md5";

	if ('Y' eq missing_file($merged_somatic_output . ".md5")) {

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'merge_genotyped_somatic_svs',
			cmd	=> $merge_somatic_svs,
			dependencies	=> join(':', @part2_jobs),
			modules		=> [$delly, $samtools],
			max_time	=> $parameters->{merge}->{time},
			mem		=> $parameters->{merge}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$merge_run_id = submit_job(
			jobname		=> 'merge_genotyped_somatic_svs',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $merge_run_id;
		}
	else {
		print $log "Skipping final merge because this has already been completed!\n";
		}

	print $log "\nFinalizing somatic SVs for each sample...\n\n";

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @tumour_ids = sort keys %{$smp_data->{$patient}->{'tumour'}};

		next if (scalar(@tumour_ids) == 0);

		my $patient_directory = join('/', $output_directory, $patient);

		# for each tumour sample
		foreach my $sample (@tumour_ids) {

			print $log ">>TUMOUR: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			my $sample_sheet = join('/', $sample_directory, 'sample_sheet.tsv');

			my $filter_output = join('/', $sample_directory, $sample . '_Delly_SVs_somatic_filtered.bcf');
			my $final_output = join('/', $sample_directory, $sample . '_Delly_SVs_somatic_hc.bcf');

			my $finalize_somatic_svs = get_delly_filter_command(
				input	=> $merged_somatic_output,
				output	=> $filter_output,
				type	=> 'somatic',
				samples	=> $sample_sheet
				);

			$finalize_somatic_svs .= "\n\n" . get_finalize_command(
				id		=> @{$sample_sheet_tumour{$sample}},
				output		=> $final_output,
				input		=> $filter_output
				);

			$finalize_somatic_svs .= "\n\n" . "md5sum $final_output > $final_output.md5";

			$cleanup{$patient} .= "rm $filter_output\n";

			if ('Y' eq missing_file($final_output . ".md5")) {

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'finalize_somatic_svs_' . $sample,
					cmd	=> $finalize_somatic_svs,
					dependencies	=> $merge_run_id,
					modules		=> [$delly, $samtools],
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'finalize_somatic_svs_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				}

			push @{$final_outputs{$patient}}, $final_output;
			}

		# should intermediate files be removed
		if ( ($args{del_intermediates}) && (scalar(@{$patient_jobs{$patient}}) > 0) ) {

			print $log "\nSubmitting job to clean up temporary/intermediate files...\n";

			# make sure final output exists before removing intermediate files!
			my $cleanup_cmd = join("\n",
				"if [ -s " . join(" ] && [ -s ", @{$final_outputs{$patient}}) . " ]; then",
				"  $cleanup{$patient}",
				"else",
				'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
				"fi"
				);

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_somatic_cleanup_' . $patient,
				cmd	=> $cleanup_cmd,
				dependencies	=> join(':', @{$patient_jobs{$patient}}),
				mem		=> '256M',
				hpc_driver	=> $args{hpc_driver},
				kill_on_error	=> 0
				);

			$run_id = submit_job(
				jobname		=> 'run_somatic_cleanup_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);
			}

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @{$final_outputs{$patient}}) . "\n";
		print $log "---\n";
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0
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
					die("Final DELLY accounting job: $run_id finished with errors.");
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
my ($tool_config, $data_config, $output_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $germline, $help, $no_wait);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry-run'	=> \$dry_run,
	'no-wait'	=> \$no_wait,
	'germline'	=> \$germline
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--germline\t<boolean> look for germline variants (only looks at normal samples)? (NOT TESTED!! default: false)",
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
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

if ($germline) {
	pon(
		tool_config		=> $tool_config,
		data_config		=> $data_config,
		output_directory	=> $output_directory,
		hpc_driver		=> $hpc_driver,
		del_intermediates	=> $remove_junk,
		dry_run			=> $dry_run,
		no_wait			=> $no_wait
		);

	} else {

	main(
		tool_config		=> $tool_config,
		data_config		=> $data_config,
		output_directory	=> $output_directory,
		hpc_driver		=> $hpc_driver,
		del_intermediates	=> $remove_junk,
		dry_run			=> $dry_run,
		no_wait			=> $no_wait
		);
	}
