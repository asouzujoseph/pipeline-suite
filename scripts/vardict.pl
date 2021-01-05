#!/usr/bin/env perl
### vardict.pl #####################################################################################
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
use List::Util 'first';
use IO::Handle;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $pon, $intervals_bed) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run VarDict (java)

### USAGE ##########################################################################################
# vardict.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to run VarScan SNV calling
sub get_vardict_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		tumour_id	=> undef,
		normal_id	=> undef,
		output		=> undef,
		intervals	=> undef,
		@_
		);

	my $vardict_command = 'DIRNAME=$(which VarDict | xargs dirname)';

	$vardict_command .= "\n\n" . join(' ',
		'VarDict',
		'-G', $reference,
		'-f 0.01',
		'-N', $args{tumour_id}
		);

	if (defined($args{intervals})) {
		$vardict_command .= " -c 1 -S 2 -E 3 $args{intervals}";
		}

	if (defined($args{normal})) {

		$vardict_command .= ' ' . join(' ',
			'-b', '"' . $args{tumour} . '|' . $args{normal} . '"',
			'| $DIRNAME/testsomatic.R',
			'| $DIRNAME/var2vcf_paired.pl',
			'-N', '"' . $args{tumour_id} . '|' . $args{normal_id} . '"',
			'-S -f 0.01',
			'>', $args{output}
			);

		} else {

		$vardict_command .= ' ' . join(' ',
			'-b', $args{tumour},
			'| $DIRNAME/teststrandbias.R',
			'| $DIRNAME/var2vcf_valid.pl',
			'-N', $args{tumour_id},
			'-S -f 0.01',
			'>', $args{output}
			);
		}

	return($vardict_command);
	}

# format command to run variant filter
sub get_filter_command {
	my %args = (
		input_vcf	=> undef,
		output_stem	=> undef,
		tmp_dir		=> undef,
		pon		=> undef,
		somatic		=> 0,
		normal_id	=> undef,
		@_
		);

	my $filter_command = "if [ ! -s $args{input_vcf}.gz.tbi ]; then\n";
	$filter_command .= "  bgzip $args{input_vcf}\n";
	$filter_command .= "  tabix -p vcf $args{input_vcf}.gz\n";
	$filter_command .= "fi\n\n";

	# if tool used was somatic (T/N pair), split snp/indel into germline/somatic 
	if ($args{somatic}) {

		$filter_command .= join(' ',
			'bcftools filter',
			"--include 'INFO/STATUS=" . '"Germline"' . " & INFO/SSF<0.05'",
			"$args{input_vcf}.gz",
			'| vcf-subset -c', $args{normal_id},
			'>', $args{output_stem} . "_germline_hc.vcf"
			);
 
		$filter_command .= "\n\n" . join(' ',
			'bcftools filter',
			"--include 'INFO/STATUS=" . '"StrongSomatic,LikelySomatic"' . " & INFO/SSF<0.05'",
			"$args{input_vcf}.gz",
			'-O v',
			'-o', $args{output_stem} . "_somatic_hc.vcf"
			);

	# else, for tumour-only, split into snp/indel
	} else {
		$filter_command .= "\n\n" . join(' ',
			'bcftools filter',
			"--include 'INFO/STATUS=" . '"StrongSomatic,LikelySomatic"' . " & INFO/SSF<0.05'",
			"$args{input_vcf}.gz",
			'-O v',
			'-o', $args{output_stem} . "_somatic_hc.vcf"
			);
		$filter_command = join(' ',
			'vcftools',
			'--vcf', $args{input_vcf},
			'--keep-filtered PASS',
			'--stdout --recode',
			'--temp', $args{tmp_dir}
			);

		if (defined($args{pon})) {
			$filter_command .= " --exclude-positions $args{pon}";
			}

		$filter_command .= ' > ' . $args{output_stem} . "_somatic_hc.vcf";
		}

	return($filter_command);
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

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		pon			=> undef,
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
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'vardict');
	my $date = strftime "%F", localtime;

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_VarDict_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_VarDict_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running VarDict variant calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};

	if (defined($tool_data->{intervals_bed})) {
		$intervals_bed = $tool_data->{intervals_bed};
		$intervals_bed =~ s/\.bed/_padding100bp.bed/;
		print $log "\n    Target intervals (exome): $intervals_bed";
		}

	if (defined($args{pon})) {
                print $log "\n    Panel of Normals: $args{pon}";
                $pon = $args{pon};
                } elsif (defined($tool_data->{vardict}->{pon})) {
		print $log "\n    Panel of Normals: $tool_data->{vardict}->{pon}";
		$pon = $tool_data->{vardict}->{pon};
		} else {
		print $log "\n    No panel of normals provided; will attempt to create one.";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $vardict	= 'vardictjava/' . $tool_data->{vardict_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $gatk	= 'gatk/' . $tool_data->{gatk_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{vardict}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link, $cleanup_cmd);
	my (@all_jobs, @pon_vcfs, @pon_dependencies);

	my $pon_directory = join('/', $output_directory, 'PanelOfNormals');
	unless(-e $pon_directory) { make_path($pon_directory); }

	my $pon_intermediates = join('/', $pon_directory, 'intermediate_files');
	unless(-e $pon_intermediates) { make_path($pon_intermediates); }

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		next if (scalar(@normal_ids) == 0);

		print $log "\nInitiating process for PATIENT: $patient\n";

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless(-e $tmp_directory) { make_path($tmp_directory); }

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
		my (@patient_jobs, @final_outputs, @germline_vcfs, @germline_jobs);

		# indicate this should be removed at the end
		$cleanup_cmd = "rm -rf $tmp_directory";

		# for each tumour sample
		foreach my $sample (@tumour_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$run_id = '';

			# create output stem
			my $output_stem = join('/', $sample_directory, $sample . '_VarDict');

			$cleanup_cmd .= "\nrm $output_stem.vcf.gz";

			my $vardict_command = get_vardict_command(
				tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
				normal		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
				tumour_id	=> $sample,
				normal_id	=> $normal_ids[0],
				output		=> $output_stem . '.vcf',
				intervals	=> $intervals_bed
				);

			$vardict_command .= "\n\n" . join("\n",
				'if [ $? == 0 ]; then',
				"  md5sum $output_stem.vcf > $output_stem.vcf.md5",
				'fi'
				);

			# check if this should be run
			if ('Y' eq missing_file($output_stem . ".vcf.md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VarDict (java)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vardict_' . $sample,
					cmd	=> $vardict_command,
					modules	=> ['perl', $vardict, $r_version],
					max_time	=> $parameters->{vardict}->{time},
					mem		=> $parameters->{vardict}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vardict_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping VarDict because this has already been completed!\n";
				}

			# filter results
			$cleanup_cmd .= "\nrm " . $output_stem . '_somatic_hc.vcf';

			my $filter_command = get_filter_command(
				input_vcf	=> $output_stem . '.vcf', 
				output_stem	=> $output_stem,
				somatic		=> 1,
				normal_id	=> $normal_ids[0]
				);

			$filter_command .= "\n\n" . join(' ',
				'md5sum', $output_stem . '_somatic_hc.vcf',
				'>', $output_stem . '_somatic_hc.vcf.md5'
				);

			$filter_command .= "\n\n" . join(' ',
				'md5sum', $output_stem . '_germline_hc.vcf',
				'>', $output_stem . '_germline_hc.vcf.md5'
				);

			$filter_command .= "\n\n" . join(' ',
				'mv', $output_stem . '_germline_hc.vcf*',
				$pon_intermediates
				);

			my $new_germline = join('/',
				$pon_intermediates,
				$sample . '_VarDict_germline_hc.vcf'
				);

			$filter_command .= "\n\n" . join(' ',
				'bgzip', $new_germline . "\n",
				'tabix -p vcf', $new_germline . '.gz'
				);

			push @germline_vcfs, $new_germline . '.gz';

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '_somatic_hc.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VCF-Filter...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf_filter_' . $sample,
					cmd	=> $filter_command,
					modules	=> [$samtools, 'tabix', $vcftools],
					dependencies	=> $run_id,
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vcf_filter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @germline_jobs, $run_id;
				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;

				} else {
				print $log "Skipping VCF-Filter because this has already been completed!\n";
				}

			### Run variant annotation (VEP + vcf2maf)
			my ($vcf2maf_cmd, $final_maf, $final_vcf);

			$final_maf = $output_stem . '_somatic_annotated.maf';
			$final_vcf = $output_stem . '_somatic_annotated.vcf';

			$vcf2maf_cmd = get_vcf2maf_command(
				input		=> $output_stem . '_somatic_hc.vcf',
				tumour_id	=> $sample,
				normal_id	=> $normal_ids[0],
				reference	=> $reference,
				ref_type	=> $tool_data->{ref_type},
				output		=> $final_maf,
				tmp_dir		=> $tmp_directory,
				vcf2maf		=> $tool_data->{annotate}->{vcf2maf_path},
				vep_path	=> $tool_data->{annotate}->{vep_path},
				vep_data	=> $tool_data->{annotate}->{vep_data},
				filter_vcf	=> $tool_data->{annotate}->{filter_vcf}
				);

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample\_VarDict_somatic_hc.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "Submitting job for T/N vcf2maf...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf2maf_and_VEP_' . $sample,
					cmd	=> $vcf2maf_cmd,
					modules	=> ['perl', $samtools, 'tabix'],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{annotate}->{time},
					mem		=> $tool_data->{annotate}->{mem}->{snps},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vcf2maf_and_VEP_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping vcf2maf because this has already been completed!\n";
				}

			push @final_outputs, $final_maf;
			}

		# before making the PoN, we will merge snp/indel results
		# as well as collapsing results from multi-tumour patients
		if ( (!defined($pon)) && (scalar(@normal_ids) > 0) ) {

			# for any germline calls from T/N pairs
			my $merged_germline = join('/',
				$pon_intermediates,
				$patient . '_germline_variants.vcf'
				);

			my $format_germline_cmd;

			# for multiple tumours, collect all variants, then subset the normal
			if (scalar(@tumour_ids) == 1) {

				push @pon_vcfs, "-V:$patient $germline_vcfs[0]";
				push @pon_dependencies, $germline_jobs[0];

				} elsif (scalar(@tumour_ids) > 1) {

				$format_germline_cmd = join(' ',
					'vcf-isec -n +1',
					@germline_vcfs,
					'>', $merged_germline
					);

				$format_germline_cmd .= "\n\n" . join("\n",
					"md5sum $merged_germline > $merged_germline.md5",
					"bgzip $merged_germline",
					"tabix -p vcf $merged_germline.gz"
					);

				push @pon_vcfs, "-V:$patient $merged_germline.gz";

				if ('Y' eq missing_file($merged_germline . '.md5')) {

					# record command (in log directory) and then run job
					print $log "Submitting job for PoN prep...\n";

					$run_script = write_script(
						log_dir	=> $log_directory,
						name	=> 'collapse_germline_calls_' . $patient,
						cmd	=> $format_germline_cmd,
						modules	=> ['perl', $vcftools, 'tabix'],
						dependencies	=> join(':', @germline_jobs),
						max_time	=> '06:00:00',
						mem		=> '1G',
						hpc_driver	=> $args{hpc_driver}
						);

					$run_id = submit_job(
						jobname		=> 'collapse_germline_calls_' . $patient,
						shell_command	=> $run_script,
						hpc_driver	=> $args{hpc_driver},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);

					push @pon_dependencies, $run_id;
					push @patient_jobs, $run_id;
					push @all_jobs, $run_id;
					}
				}
			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) == 0) {
				`rm -rf $tmp_directory`;
				} else {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my @files_to_check;
				foreach my $tmp ( @final_outputs ) {
					push @files_to_check, $tmp . '.md5';
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
					dependencies	=> join(':', @patient_jobs),
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_cleanup_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);
				}
			}

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# create a panel of normals if not provided
	my $pon_job_id = '';

	unless (defined($pon)) {

		# let's create a command and write script to combine variants for a PoN
		$pon		= join('/', $pon_directory, $date . "_merged_panelOfNormals_trimmed.vcf");
		my $final_pon_link = join('/', $output_directory, 'panel_of_normals.vcf');

		# create a trimmed (sites only) output (this is the panel of normals)
		my $pon_command = generate_pon(
			input		=> join(' ', @pon_vcfs),
			output		=> $pon,
			java_mem	=> $parameters->{combine}->{java_mem},
			tmp_dir		=> $output_directory,
			out_type	=> 'trimmed'
			);

		if (-l $final_pon_link) {
			unlink $final_pon_link or die "Failed to remove previous symlink: $final_pon_link";
			}

		symlink($pon, $final_pon_link);

		$pon_command .= "\n" . check_java_output(
			extra_cmd => "  md5sum $pon > $pon.md5"
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'create_sitesOnly_trimmed_panel_of_normals',
			cmd	=> $pon_command,
			modules	=> [$gatk],
			dependencies	=> join(':', @pon_dependencies),
			max_time	=> $parameters->{combine}->{time},
			mem		=> $parameters->{combine}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$pon_job_id = submit_job(
			jobname		=> 'create_sitesOnly_trimmed_panel_of_normals',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		$pon = $final_pon_link;
		}

	# now that we have a PoN, resume processing tumour-only samples
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		next if (scalar(@normal_ids) > 0);

		print $log "\nResuming process for PATIENT: $patient\n";

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless(-e $tmp_directory) { make_path($tmp_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $tumour (@tumour_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);
			}

		# create an array to hold final outputs and all patient job ids
		my (@patient_jobs, @final_outputs);

		# indicate this should be removed at the end
		$cleanup_cmd = "rm -rf $tmp_directory";

		# for each tumour sample
		foreach my $sample (@tumour_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$run_id = '';

			# create output stem
			my $output_stem = join('/', $sample_directory, $sample . '_VarDict');

			$cleanup_cmd .= "\nrm $output_stem.vcf.gz";

			my $vardict_command = get_vardict_command(
				tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
				tumour_id	=> $sample,
				output		=> $output_stem . '.vcf',
				intervals	=> $intervals_bed
				);

			$vardict_command .= "\n\n" . join("\n",
				'if [ $? == 0 ]; then',
				"  md5sum $output_stem.vcf > $output_stem.vcf.md5",
				'fi'
				);

			# check if this should be run
			if ('Y' eq missing_file($output_stem . ".vcf.md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VarDict (java)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vardict_' . $sample,
					cmd	=> $vardict_command,
					modules	=> ['perl', $vardict, $r_version],
					max_time	=> $parameters->{vardict}->{time},
					mem		=> $parameters->{vardict}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vardict_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping VarDict because this has already been completed!\n";
				}

			# filter results
			$cleanup_cmd .= "\nrm " . $output_stem . '_somatic_hc.vcf';

			my $filter_command = get_filter_command(
				input_vcf	=> $output_stem . '.vcf', 
				output_stem	=> $output_stem,
				somatic		=> 0,
				tmp_dir		=> $tmp_directory,
				pon		=> $pon
				);

			$filter_command .= "\n\n" . join(' ',
				'md5sum', $output_stem . '_somatic_hc.vcf',
				'>', $output_stem . '_somatic_hc.vcf.md5'
				);

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '_somatic_hc.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VCF-Filter...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf_filter_' . $sample,
					cmd	=> $filter_command,
					modules	=> [$samtools, 'tabix', $vcftools],
					dependencies	=> join(':', $run_id, $pon_job_id),
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vcf_filter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;

				} else {
				print $log "Skipping VCF-Filter because this has already been completed!\n";
				}

			### Run variant annotation (VEP + vcf2maf)
			my $final_maf = $output_stem . '_somatic_annotated.maf';
			my $final_vcf = $output_stem . '_somatic_annotated.vcf';

			my $vcf2maf_cmd = get_vcf2maf_command(
				input		=> $output_stem . '_somatic_hc.vcf',
				tumour_id	=> $sample,
				reference	=> $reference,
				ref_type	=> $tool_data->{ref_type},
				output		=> $final_maf,
				tmp_dir		=> $tmp_directory,
				vcf2maf		=> $tool_data->{annotate}->{vcf2maf_path},
				vep_path	=> $tool_data->{annotate}->{vep_path},
				vep_data	=> $tool_data->{annotate}->{vep_data},
				filter_vcf	=> $tool_data->{annotate}->{filter_vcf}
				);

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample\_VarDict_somatic_hc.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "Submitting job for tumour-only vcf2maf...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf2maf_and_VEP_' . $sample,
					cmd	=> $vcf2maf_cmd,
					modules	=> ['perl', $samtools, 'tabix'],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{annotate}->{time},
					mem		=> $tool_data->{annotate}->{mem}->{snps},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vcf2maf_and_VEP_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping vcf2maf because this has already been completed!\n";
				}

			push @final_outputs, $final_maf;
			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) == 0) {
				`rm -rf $tmp_directory`;
				} else {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my @files_to_check;
				foreach my $tmp ( @final_outputs ) {
					push @files_to_check, $tmp . '.md5';
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
					dependencies	=> join(':', @patient_jobs),
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_cleanup_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);
				}
			}

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# collate results
	my $collect_output = join(' ',
		"Rscript $cwd/collect_snv_output.R",
		'-d', $output_directory,
		'-p', $tool_data->{project_name}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_variant_calls',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '4G',
		max_time	=> '12:00:00',
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'combine_variant_calls',
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

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
					die("Final VARDICT accounting job: $run_id finished with errors.");
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
my ($remove_junk, $dry_run, $help, $no_wait);
my $panel_of_normals = undef;

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
	'pon=s'		=> \$panel_of_normals
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--pon\t<string> path to panel of normals (optional)",
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

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	pon			=> $panel_of_normals,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
