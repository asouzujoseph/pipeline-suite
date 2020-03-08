### create_final_yaml.pl ###########################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use Getopt::Std;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);
use File::Basename;
use File::Path qw(make_path);
require "./utilities.pl";

### GETOPTS PLUS ERROR CHECKING AND DEFAULT VALUES #################################################
# declare variables
my $data_directory;
my $output_config;

# identify pattern to use
my $pattern = '.bam$';
my $data_type = 'dna';

# read in command line arguments
GetOptions(
	'd|data_dir=s'		=> \$data_directory,
	'p|pattern=s'		=> \$pattern,
	'o|output_config=s'	=> \$output_config,
	't|data_type=s'		=> \$data_type
	);

# check for and remove trailing / from data dir
$data_directory =~ s/\/$//;

### HANDLING FILES #################################################################################
# open output file
open (my $fh, '>', $output_config) or die "Cannot open '$output_config' !";
print $fh "---\n";

# find all patient/subject directories
opendir(SUBJECTS, $data_directory) or die "Cannot open '$data_directory' !";
my @subject_dirs = grep { !/logs|^\./ && -d "$data_directory/$_" } readdir(SUBJECTS);
closedir(SUBJECTS);

my @subject_names = ();

# process each patient in SUBJECTS
foreach my $subject (sort(@subject_dirs)) {

	my $subject_directory = join('/', $data_directory, $subject);

	# if the subject has already been written (if multiple samples per patient)
	if (grep /$subject/, @subject_names) {
		print "$subject already exists; continuing with next sample for this patient\n";
		}
	else {
		push @subject_names, $subject;
		print $fh "$subject:\n";
		}

	my @normals = ();
	my @tumours = ();

	# find sample directories
	opendir(BAMFILES, $subject_directory) or die "Cannot open '$subject_directory' !";
	my @bam_files = grep {/$pattern/} readdir(BAMFILES);
	closedir(BAMFILES);

	my $sample;
	foreach my $bam (sort(@bam_files)) {

		my @sample_parts = split(/\_/, $bam);
		$sample = $sample_parts[0];

		if ($sample =~ m/BC|SK|A/) {
			push @normals, $sample . ": " . $subject_directory . "/" . $bam;
			} else {
			push @tumours, $sample . ": " . $subject_directory . "/" . $bam;
			}
		}

	if (scalar(@normals) > 0) {
		print $fh "    normal:\n";
		foreach my $normal (sort(@normals)) {
			print $fh "        $normal\n";
			}
		}

	if (scalar(@tumours) > 0) {
		print $fh "    tumour:\n";
		foreach my $tumour (sort(@tumours)) {
			print $fh "        $tumour\n";
			}
		}
	}

close $fh;
exit;
