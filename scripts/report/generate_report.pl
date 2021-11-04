#!/usr/bin/env perl
### generate_report.pl #############################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use List::Util qw(any all first);
use List::MoreUtils qw(first_index);
use YAML qw(LoadFile);

####################################################################################################
# version       author		comment
# 1.0		sprokopec       tool to automatically generate reports

### USAGE ##########################################################################################
# generate_report.pl -d DATA_DIRECTORY -o OUTPUT_DIRECTORY
#
# where:

### MAIN ###########################################################################################
sub main {
	my %args = (
		output_dir	=> undef,
		input_dir	=> undef,
		title		=> undef,
		run_date	=> undef,
		@_
		);

	# ensure no special characters in title
	$args{title} =~ s/_/\\_/;

	# find all input files
	opendir(PLOTS, $args{input_dir}) or die $!;
	my @input_files = readdir(PLOTS);
	closedir(PLOTS);

	my @plot_files = grep { /png$/ } @input_files;
	@plot_files = sort @plot_files;

	my @tex_files = grep { /tex$/ } @input_files;
	@tex_files = sort @tex_files;

	my @output_tex_files;

	# if multiple cna callers were run
	my @cnv_tex;
	if (any { /cna_summary.tex/ } @tex_files) {
		push @cnv_tex, 'cna_summary.tex';
		@tex_files = grep { $_ ne 'cna_summary.tex' } @tex_files;
		}
	if (any { /cna_summary_gatk.tex/ } @tex_files) {
		push @cnv_tex, 'cna_summary_gatk.tex';
		@tex_files = grep { $_ ne 'cna_summary_gatk.tex' } @tex_files;
		}
	if (any { /cna_summary_mops.tex/ } @tex_files) {
		push @cnv_tex, 'cna_summary_mops.tex';
		@tex_files = grep { $_ ne 'cna_summary_mops.tex' } @tex_files;
		}
	if (any { /cna_summary_ichor.tex/ } @tex_files) {
		push @cnv_tex, 'cna_summary_ichor.tex';
		@tex_files = grep { $_ ne 'cna_summary_ichor.tex' } @tex_files;
		}

	foreach my $i ( @cnv_tex) {
		next if ($i eq $cnv_tex[0]);
		my $filepath = join('/', $args{input_dir}, $i);
		`sed -i 's/section{SCNA Summary}/pagebreak/' $filepath`;
		}

	push @output_tex_files, @cnv_tex;

	# add in germline SNV summary
	if (any { /germline_snv_summary/ } @tex_files) {
		push @output_tex_files, 'germline_snv_summary.tex';
		@tex_files = grep { $_ ne 'germline_snv_summary.tex' } @tex_files;
		}

	# add in somatic SNV summary
	if (any { /somatic_snv_summary/ } @tex_files) {
		push @output_tex_files, 'somatic_snv_summary.tex';
		@tex_files = grep { $_ ne 'somatic_snv_summary.tex' } @tex_files;
		}

	# add in OncoKB summary
	if (any { /oncokb_summary/ } @tex_files) {
		push @output_tex_files, 'oncokb_summary.tex';
		@tex_files = grep { $_ ne 'oncokb_summary.tex' } @tex_files;
		}

	# put the remaining tex files into output array
	push @output_tex_files, @tex_files;

	# find QC input
	my @qc_plots = grep { /qc_metrics.png$/ } @plot_files;
	my $most_recent_qc_plot = $qc_plots[-1];

	open(my $report_file, '>', $args{output_dir} . "/Report.tex");
	print $report_file <<EOI;

\\documentclass[12pt]{report}
\\usepackage{fancyhdr}
\\usepackage{graphicx}
\\usepackage{lastpage}
\\usepackage{caption}
\\usepackage{subcaption}
\\usepackage{url}
\\usepackage[margin=1in]{geometry}

\\pagestyle{fancy}
\\lfoot{PughLab Pipeline-Suite}
\\rfoot{Run Date: \\today}
\\cfoot{Page \\thepage\\ of \\pageref{LastPage}}

\\title{\\Huge \\bf PughLab Pipeline-Suite Output Report@{[defined $args{title} ? ": $args{title}" : ""]}}

\\date{
	Pipeline was initiated on $args{run_date}.\\\\
	\\centerline{This report was generated on \\today}}

\\renewcommand\\thesection{\\arabic{section}}

\\begin{document}

\\maketitle
\\thispagestyle{fancy}

\\pagebreak

\\section{Description}
This report was auto-generated by the PughLab Pipeline-Suite. The \\LaTeX \\ file used to generate this report is located at:\\newline
{\\scriptsize \\path{$args{output_dir}/Report.tex}}

\\input{$args{input_dir}/methods.tex}

\\pagebreak

\\section{QC}
\\begin{figure}[h!]
\\begin{center}
\\includegraphics[width=0.9\\textwidth]{$args{input_dir}/$most_recent_qc_plot}
\\end{center}
\\input{$args{input_dir}/qc_plot_caption.tex}
\\end{figure}

\\pagebreak

\\input{$args{input_dir}/qc_concerns.tex}
EOI

	foreach my $part ( @output_tex_files ) {
		next if ('qc_plot_caption.tex' eq $part);
		next if ('qc_concerns.tex' eq $part);
		next if ('methods.tex' eq $part);
		next if ($part =~ /^\./);

		my $tex_path = $args{input_dir} . '/' . $part;

		print $report_file "\\pagebreak\n";
		print $report_file "\\input{$tex_path}\n";
		}

	print $report_file "\\end{document}\n";

	close $report_file;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($help, $input_directory, $output_directory, $title, $run_date);

# get command line arguments
GetOptions(
	'h|help'		=> \$help,
	'i|input_dir=s'		=> \$input_directory,
	'o|output_dir=s'	=> \$output_directory,
	'd|date=s'		=> \$run_date,
	't|title=s'		=> \$title
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--title|-t\t<string> Title for the report",
		"\t--date|-d\t<string> Date the pipeline was initiated",
		"\t--input_dir|-i\t<string> Path to input (plot) directory",
		"\t--output_dir|-o\t<string> Path to output (report) directory"
		);

	print $help_msg . "\n";
	exit;
	}

# do some quick error checks to confirm valid arguments	
main(
	run_date	=> $run_date,
	output_dir	=> $output_directory,
	input_dir	=> $input_directory,
	title		=> $title
	);
