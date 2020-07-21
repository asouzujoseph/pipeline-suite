#!/usr/bin/env perl
### mutect.pl ######################################################################################
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
our ($reference, $dbsnp, $cosmic, $pon) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run MuTect1 with options for T/N, PoN and T only
# 1.1		sprokopec	minor updates for compatibility with larger pipeline

### USAGE ##########################################################################################
# mutect.pl -t tool.yaml -d data.yaml { --create-panel-of-normals } -o /path/to/output/dir -h slurm -r Y -n Y
#
# where:
# 	- tool.yaml contains tool versions and parameters, reference information, etc.
# 	- data.yaml contains sample information (YAML file containing paths to BWA-aligned,
# 	GATK-processed BAMs, generated by gatk.pl)
# 	-o /path/to/output/dir indicates tool-specific output directory
# 	-h indicates hpc driver (ie, slurm)
# 	-r indicates whether or not to remove intermediate files (Y/N)
# 	-n indicates whether or not this is a dry run (Y/N)
# 	--create-panel-of-normals for generating PoN

# NOTE: Final step of PoN generation uses GATK CombineVariants which outputs VCFv4.2
# 	MuTect requires VCFv4.1 - to address this, you must manually change the VCF header:
# 		##fileformat=VCFv4.2 to ##fileformat=VCFv4.1
# 		##FORMAT=<ID=AD,Number=R to ##FORMAT=<ID=AD,Number=.
# 	This manual change is necessary as vcf-convert does not change the second part.

### DEFINE SUBROUTINES #############################################################################
# format command to run MuTect in artifact detection mode
sub get_mutect_pon_command {
	my %args = (
		normal		=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		intervals	=> undef,
		@_
		);

	my $mutect_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $mutect_dir/muTect.jar -T MuTect',
		'-R', $reference,
		'--input_file:tumor', $args{normal},
		'--vcf', $args{output_stem} . '.vcf',
		'--artifact_detection_mode',
		'--dbsnp', $dbsnp
		);

	if (defined($cosmic)) {
		$mutect_command .= " --cosmic $cosmic";
		}

	if (defined($args{intervals})) {
		$mutect_command .= ' ' . join(' ',
			'--intervals', $args{intervals},
			'--interval_padding 100'
			);
		}

	return($mutect_command);
	}

# format command to generate PON
sub  generate_pon {
	my %args = (
		input		=> undef,
		output		=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		out_type	=> 'full',
		@_
		);

	my $pon_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T CombineVariants',
		'-R', $reference,
		$args{input},
		'-o', $args{output},
		'--filteredrecordsmergetype KEEP_IF_ANY_UNFILTERED',
		'--genotypemergeoption UNSORTED --filteredAreUncalled'
		);

	if ('trimmed' eq $args{out_type}) {
		$pon_command .= ' -minN 2 -minimalVCF -suppressCommandLineHeader --excludeNonVariants --sites_only';
		}

	return($pon_command);
	}

# format command to run MuTect on T/N pairs
sub get_mutect_tn_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		tumour_ID	=> undef,
		normal_ID	=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		intervals	=> undef,
		@_
		);

	my $mutect_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $mutect_dir/muTect.jar -T MuTect',
		'-R', $reference,
		'--input_file:tumor', $args{tumour},
		'--input_file:normal', $args{normal},
		'--tumor_sample_name', $args{tumour_ID},
		'--normal_sample_name', $args{normal_ID},
		'--vcf', $args{output_stem} . '.vcf',
		'--out', $args{output_stem} . '.stats',
		'--dbsnp', $dbsnp
		);

	if (defined($cosmic)) {
		$mutect_command .= " --cosmic $cosmic";
		}

	if (defined($pon)) {
		$mutect_command .= " --normal_panel $pon";
		}

	if (defined($args{intervals})) {
		$mutect_command .= ' ' . join(' ',
			'--intervals', $args{intervals},
			'--interval_padding 100'
			);
		}

	return($mutect_command);
	}

# format command to run MuTect on T/N pairs
sub get_mutect_tonly_command {
	my %args = (
		tumour		=> undef,
		tumour_ID	=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		intervals	=> undef,
		@_
		);

	my $mutect_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $mutect_dir/muTect.jar -T MuTect',
		'-R', $reference,
		'--input_file:tumor', $args{tumour},
		'--tumor_sample_name', $args{tumour_ID},
		'--vcf', $args{output_stem} . '.vcf',
		'--out', $args{output_stem} . '.stats',
		'--dbsnp', $dbsnp,
		'--normal_panel', $pon
		);

	if (defined($cosmic)) {
		$mutect_command .= " --cosmic $cosmic";
		}

	if (defined($args{intervals})) {
		$mutect_command .= ' ' . join(' ',
			'--intervals', $args{intervals},
			'--interval_padding 100'
			);
		}

	return($mutect_command);
	}

# format command to run variant filter
sub get_filter_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $filter_command = join(' ',
		'vcftools',
		'--vcf', $args{input},
		'--remove-filtered REJECT',
		'--stdout --recode',
		'--temp', $args{tmp_dir},
		'>', $args{output}
		);

	return($filter_command);
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

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, '..', 'logs', 'CREATE_PanelOfNormals');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_MuTect_GeneratePoN_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	if ('N' eq $tool_data->{dry_run}) {
		# initiate a file to hold job metrics
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_MuTect_GeneratePoN_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";

	print $log "---\n";
	print $log "Running MuTect Panel of Normals pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	
	if (defined($tool_data->{dbsnp})) {
		print $log "\n      dbSNP: $tool_data->{dbsnp}";
		$dbsnp = $tool_data->{dbsnp};
		} elsif ('hg38' eq $tool_data->{ref_type}) {
		$dbsnp = '/cluster/tools/data/genomes/human/hg38/hg38bundle/dbsnp_144.hg38.vcf.gz';
		} elsif ('hg19' eq $tool_data->{ref_type}) {
		$dbsnp = '/cluster/tools/data/genomes/human/hg19/variantcallingdata/dbsnp_138.hg19.vcf';
		}

	if (defined($tool_data->{cosmic})) {
		print $log "\n      COSMIC: $tool_data->{cosmic}";
		$cosmic = $tool_data->{cosmic};
		}

	if (defined($tool_data->{intervals_bed})) {
		print $log "\n    Target intervals (exome): $tool_data->{intervals_bed}";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $mutect	= 'mutect/' . $tool_data->{tool_version};
	my $gatk	= 'gatk/' . $tool_data->{gatk_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link, $java_check, $cleanup_cmd);
	my (@all_jobs, @pon_vcfs);

	# create some directories
	my $link_directory = join('/', $output_directory, 'bam_links');
	unless(-e $link_directory) { make_path($link_directory); }

	my $intermediate_directory = join('/', $output_directory, 'intermediate_files');
	unless(-e $intermediate_directory) { make_path($intermediate_directory); }

	my $tmp_directory = join('/', $output_directory, 'TEMP');
	unless(-e $tmp_directory) { make_path($tmp_directory); }

	# indicate this should be removed at the end
	$cleanup_cmd = "rm -rf $tmp_directory";

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};

		if (scalar(@normal_ids) == 0) {
			print $log "\n>> No normal BAM provided, skipping patient.\n";
			next;
			}

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs);
		$run_id = $args{dependencies};
		$java_check = '';

		# run each available sample
		foreach my $sample (@normal_ids) {

			# create some symlinks
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$sample};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$sample}, $link);

			print $log "  SAMPLE: $sample\n\n";

			# run MuTect
			my $output_stem = join('/', $intermediate_directory, $sample . '_MuTect');
			$cleanup_cmd .= "\nrm $output_stem.vcf";

			my $mutect_command = get_mutect_pon_command(
				normal		=> $smp_data->{$patient}->{normal}->{$sample},
				output_stem	=> $output_stem,
				java_mem	=> $tool_data->{parameters}->{mutect}->{java_mem},
				tmp_dir		=> $tmp_directory,
				intervals	=> $tool_data->{intervals_bed}
				);

			# this is a java-based command, so run a final check
			my $java_check = "\n" . check_java_output(
				extra_cmd => "\n\nmd5sum $output_stem.vcf > $output_stem.vcf.md5"
				);

			$mutect_command .= "\n$java_check";

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for MuTect in artifact_detection_mode...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_mutect_artifact_detection_mode_' . $sample,
					cmd	=> $mutect_command,
					modules	=> [$mutect],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{mutect}->{time},
					mem		=> $tool_data->{parameters}->{mutect}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_mutect_artifact_detection_mode_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping MuTect (artifact_detection) because this has already been completed!\n";
				}

			# filter results
			my $filter_command = get_filter_command(
				input	=> $output_stem . '.vcf',
				output	=> $output_stem . '_filtered.vcf',
				tmp_dir	=> $tmp_directory
				);

			$filter_command .= "\n\n" . join(' ',
				'md5sum', $output_stem . "_filtered.vcf",
				'>', $output_stem . "_filtered.vcf.md5"
				);

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '_filtered.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VCF-filter...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_post-mutect_filter_' . $sample,
					cmd	=> $filter_command,
					modules	=> [$vcftools],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{filter}->{time},
					mem		=> $tool_data->{parameters}->{filter}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_post-mutect_filter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping VCF-filter because this has already been completed!\n";
				}

			push @pon_vcfs, join(' ', "-V:$sample", $output_stem . "_filtered.vcf");
			} # end sample
		} # end patient

	# combine results
	my $pon_tmp	= join('/', $output_directory, $date . "_merged_panelOfNormals.vcf");
	my $pon		= join('/', $output_directory, $date . "_merged_panelOfNormals_trimmed.vcf");

	# create a fully merged output (useful for combining with other studies later)
	my $full_merge_command = generate_pon(
		input		=> join(' ', @pon_vcfs),
		output		=> $pon_tmp,
		java_mem	=> $tool_data->{parameters}->{combine}->{java_mem}, 
		tmp_dir		=> $tmp_directory
		);

	$full_merge_command .= "\n" . check_java_output(
		extra_cmd => "md5sum $pon_tmp > $pon_tmp.md5;\ngzip $pon_tmp;"
		);

	# check if this should be run
	if ('Y' eq missing_file($pon_tmp . ".md5")) {

		# record command (in log directory) and then run job
		print $log "Submitting job for CombineVariants...\n";
		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_combine_vcfs_full_output',
			cmd	=> $full_merge_command,
			modules	=> [$gatk],
			dependencies	=> join(',', @all_jobs),
			max_time	=> $tool_data->{parameters}->{combine}->{time},
			mem		=> $tool_data->{parameters}->{combine}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'run_combine_vcfs_full_output',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;
		}
	else {
		print $log "Skipping CombineVariants (full) because this has already been completed!\n";
		}

	# create a trimmed output (minN 2, sites_only) to use as pon
	my $trimmed_merge_command = generate_pon(
		input		=> join(' ', @pon_vcfs),
		output		=> $pon,
		java_mem	=> $tool_data->{parameters}->{combine}->{java_mem}, 
		tmp_dir		=> $tmp_directory,
		out_type	=> 'trimmed'
		);

	my $final_link = join('/', $output_directory, '..', 'panel_of_normals.vcf');
	if (-l $final_link) {
		unlink $final_link or die "Failed to remove previous symlink: $final_link";
		}

	symlink($pon, $final_link);

	my $extra_args = join("\n",
		"  md5sum $pon > $pon.md5",
		"\n  sed -i 's/VCFv4.2/VCFv4.1/g' $pon",
		"  sed -i 's/AD,Number=R/AD,Number=./g' $pon"
		);

	$trimmed_merge_command .= "\n" . check_java_output(
		extra_cmd => $extra_args
		);

	# check if this should be run
	if ('Y' eq missing_file($pon . ".md5")) {

		# record command (in log directory) and then run job
		print $log "Submitting job for Generate PanelOfNormals...\n";
		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_combine_vcfs_and_trim',
			cmd	=> $trimmed_merge_command,
			modules	=> [$gatk],
			dependencies	=> join(',', @all_jobs),
			max_time	=> $tool_data->{parameters}->{combine}->{time},
			mem		=> $tool_data->{parameters}->{combine}->{mem},
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'run_combine_vcfs_and_trim',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;
		}
	else {
		print $log "Skipping Generate PanelOfNormals because this has already been completed!\n";
		}

	# should intermediate files be removed
	if ('Y' eq $tool_data->{del_intermediates}) {

		print $log "Submitting job to clean up temporary/intermediate files...\n";

		# make sure final output exists before removing intermediate files!
		$cleanup_cmd = join("\n",
			"if [ -s $pon.md5 ]; then",
			"  $cleanup_cmd",
			"else",
			'  "FINAL trimmed file is missing; not removing intermediates"',
			"fi"
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_cleanup',
			cmd	=> $cleanup_cmd,
			dependencies	=> join(',', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'run_cleanup',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);
		}

	print $log "\nFINAL OUTPUT: $final_link\n";
	print $log "---\n";

	# should job metrics be collected
	if ('N' eq $tool_data->{dry_run}) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(',', @all_jobs),
			mem		=> '1G',
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run},
			log_file	=> $log
			);

		# print the final job id to stdout to be collected by the master pipeline
		print $run_id;
		} else {
		print '000000';
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;

	} # end sub

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		pon			=> undef,
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

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs', 'RUN_SOMATIC_VARIANTCALL');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_MuTect_SomaticVariant_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	if ('N' eq $tool_data->{dry_run}) {
		# initiate a file to hold job metrics
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_MuTect_SomaticVariant_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";

	print $log "---\n";
	print $log "Running MuTect variant calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	
	if (defined($tool_data->{dbsnp})) {
		print $log "\n      dbSNP: $tool_data->{dbsnp}";
		$dbsnp = $tool_data->{dbsnp};
		} elsif ('hg38' eq $tool_data->{ref_type}) {
		$dbsnp = '/cluster/tools/data/genomes/human/hg38/hg38bundle/dbsnp_144.hg38.vcf.gz';
		} elsif ('hg19' eq $tool_data->{ref_type}) {
		$dbsnp = '/cluster/tools/data/genomes/human/hg19/variantcallingdata/dbsnp_138.hg19.vcf';
		}

	if (defined($tool_data->{cosmic})) {
		print $log "\n      COSMIC: $tool_data->{cosmic}";
		$cosmic = $tool_data->{cosmic};
		}

	if (defined($tool_data->{pon})) {
		print $log "\n      Panel of Normals: $tool_data->{pon}";
		$pon = $tool_data->{pon};
		} elsif (defined($args{pon})) {
		print $log "\n      Panel of Normals: $args{pon}";
		$pon = $args{pon};
		} else {
		print $log "\n      No panel of normals defined! Tumour-only samples will not be run!!";
		}

	if (defined($tool_data->{intervals_bed})) {
		print $log "\n    Target intervals (exome): $tool_data->{intervals_bed}";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $mutect	= 'mutect/' . $tool_data->{tool_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link, $java_check, $cleanup_cmd);
	my (@all_jobs, @pon_vcfs);

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless(-e $tmp_directory) { make_path($tmp_directory); }

		# indicate this should be removed at the end
		$cleanup_cmd = "rm -rf $tmp_directory";

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);
			}
		foreach my $tumour (@tumour_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);
			}

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs);

		# for T/N or T only mode
		foreach my $sample (@tumour_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$run_id = $args{dependencies};
			$java_check = '';

			# run MuTect
			my $output_stem = join('/', $sample_directory, $sample . '_MuTect');
			$cleanup_cmd .= "\nrm $output_stem.vcf";

			my $mutect_command = undef;

			# Tumour only, with a panel of normals
			if ( (defined($pon)) && (scalar(@normal_ids) == 0) ) {

				$mutect_command = get_mutect_tonly_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					tumour_ID	=> $sample,
					output_stem	=> $output_stem,
					java_mem	=> $tool_data->{parameters}->{mutect}->{java_mem},
					tmp_dir		=> $tmp_directory,
					intervals	=> $tool_data->{intervals_bed}
					);

				# paired tumour/normal
				} elsif (scalar(@normal_ids) > 0) {

				$mutect_command = get_mutect_tn_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					normal		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
					tumour_ID	=> $sample,
					normal_ID	=> $normal_ids[0],
					output_stem	=> $output_stem,
					java_mem	=> $tool_data->{parameters}->{mutect}->{java_mem},
					tmp_dir		=> $tmp_directory,
					intervals	=> $tool_data->{intervals_bed}
					);

				# else, skip this sample
				} else {
				next;
				}

			# this is a java-based command, so run a final check
			$java_check = "\n" . check_java_output(
				extra_cmd => "md5sum $output_stem.vcf > $output_stem.vcf.md5"
				);

			$mutect_command .= "\n$java_check";

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for MuTect...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_mutect_' . $sample,
					cmd	=> $mutect_command,
					modules	=> [$mutect],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{mutect}->{time},
					mem		=> $tool_data->{parameters}->{mutect}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_mutect_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping MuTect because this has already been completed!\n";
				}

			# filter results
			my $filter_command = get_filter_command(
				input	=> $output_stem . '.vcf',
				output	=> $output_stem . '_filtered.vcf',
				tmp_dir	=> $tmp_directory
				);

			$filter_command .= "\n" . join(' ',
				'md5sum', $output_stem . "_filtered.vcf",
				'>', $output_stem . "_filtered.vcf.md5"
				);

			$cleanup_cmd .= "\nrm " . $output_stem . "_filtered.vcf";

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '_filtered.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VCF-filter...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf_filter_' . $sample,
					cmd	=> $filter_command,
					modules	=> [$vcftools],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{filter}->{time},
					mem		=> $tool_data->{parameters}->{filter}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vcf_filter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping VCF-filter because this has already been completed!\n";
				}

			### Run variant annotation (VEP + vcf2maf)
			my $final_vcf = $output_stem . "_filtered_annotated.vcf";
			my $final_maf = $output_stem . "_filtered_annotated.maf";

			# Tumour only, with a panel of normals
			my $vcf2maf_cmd;

			if ( (defined($pon)) && (scalar(@normal_ids) == 0) ) {

				$vcf2maf_cmd = get_vcf2maf_command(
					input		=> $output_stem . "_filtered.vcf",
					tumour_id	=> $sample,
					reference	=> $reference,
					ref_type	=> $tool_data->{ref_type},
					output		=> $final_maf,
					tmp_dir		=> $tmp_directory,
					vcf2maf		=> $tool_data->{parameters}->{annotate}->{vcf2maf_path},
					vep_path	=> $tool_data->{parameters}->{annotate}->{vep_path},
					vep_data	=> $tool_data->{parameters}->{annotate}->{vep_data},
					filter_vcf	=> $tool_data->{parameters}->{annotate}->{filter_vcf}
					);

				# paired tumour/normal
				} elsif (scalar(@normal_ids) > 0) {

				$vcf2maf_cmd = get_vcf2maf_command(
					input		=> $output_stem . "_filtered.vcf",
					tumour_id	=> $sample,
					normal_id	=> $normal_ids[0],
					reference	=> $reference,
					ref_type	=> $tool_data->{ref_type},
					output		=> $final_maf,
					tmp_dir		=> $tmp_directory,
					vcf2maf		=> $tool_data->{parameters}->{annotate}->{vcf2maf_path},
					vep_path	=> $tool_data->{parameters}->{annotate}->{vep_path},
					vep_data	=> $tool_data->{parameters}->{annotate}->{vep_data},
					filter_vcf	=> $tool_data->{parameters}->{annotate}->{filter_vcf}
					);
				}

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				if ('N' eq missing_file("$tmp_directory/$sample\_MuTect_filtered.vep.vcf")) {
					`rm $tmp_directory/$sample\_MuTect_filtered.vep.vcf`;
					}

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN,
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample" . "_MuTect_filtered.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "Submitting job for vcf2maf...\n";

				$run_script = write_script(
					log_dir => $log_directory,
					name    => 'run_vcf2maf_and_VEP_' . $sample,
					cmd     => $vcf2maf_cmd,
					modules => ['perl', $samtools, 'tabix'],
					dependencies    => $run_id,
					max_time        => $tool_data->{parameters}->{annotate}->{time},
					mem             => $tool_data->{parameters}->{annotate}->{mem},
					hpc_driver      => $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname         => 'run_vcf2maf_and_VEP_' . $sample,
					shell_command   => $run_script,
					hpc_driver      => $tool_data->{HPC_driver},
					dry_run         => $tool_data->{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping vcf2maf because this has already been completed!\n";
				}

			push @final_outputs, $final_maf;
			}

		# should intermediate files be removed
		# run per patient
		if ('Y' eq $tool_data->{del_intermediates}) {

			if (scalar(@patient_jobs) == 0) {
				`rm $tmp_directory`;

				} else {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my @files_to_check;
				foreach my $tmp ( @final_outputs ) {
					$tmp .= '.md5';
					push @files_to_check, $tmp;
					}

				$cleanup_cmd = join("\n",
					"if [ -s " . join(" ] && [ -s ", @files_to_check) . " ]; then",
					"  $cleanup_cmd",
					"else",
					'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
					"fi"
					);

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_cleanup_' . $patient,
					cmd	=> $cleanup_cmd,
					dependencies	=> join(',', @patient_jobs),
					mem		=> '256M',
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_cleanup_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run},
					log_file	=> $log
					);
				}
			}	

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# should job metrics be collected
	if ('N' eq $tool_data->{dry_run}) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(',', @all_jobs),
			mem		=> '1G',
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

	# print the final job id to stdout to be collected by the master pipeline
	print $run_id;

	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($tool_config, $data_config, $create_pon, $output_directory);
my $hpc_driver = 'slurm';
my $remove_junk = 'N';
my $dry_run = 'Y';
my $dependencies = '';
my $panel_of_normals = undef;

# get command line arguments
GetOptions(
	'd|data=s'		=> \$data_config,
	't|tool=s'		=> \$tool_config,
	'o|out_dir=s'		=> \$output_directory,
	'h|hpc=s'		=> \$hpc_driver,
	'r|remove=s'		=> \$remove_junk,
	'n|dry_run=s'		=> \$dry_run,
	'depends=s'		=> \$dependencies,
	'create-panel-of-normals'	=> \$create_pon,
	'pon=s'			=> \$panel_of_normals
	);

# do some quick error checks to confirm valid arguments	
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

if ($create_pon) {
	pon(
		tool_config		=> $tool_config,
		data_config		=> $data_config,
		output_directory	=> $output_directory,
		hpc_driver		=> $hpc_driver,
		del_intermediates	=> $remove_junk,
		dry_run			=> $dry_run,
		dependencies		=> $dependencies
		);
} else {
	 main(
		tool_config		=> $tool_config,
		data_config		=> $data_config,
		output_directory	=> $output_directory,
		hpc_driver		=> $hpc_driver,
		del_intermediates	=> $remove_junk,
		dry_run			=> $dry_run,
		pon			=> $panel_of_normals,
		dependencies		=> $dependencies
		);
}
