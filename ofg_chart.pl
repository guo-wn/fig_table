#!/usr/bin/perl
use strict;
use warnings;
use autodie;

use Getopt::Long;
use YAML::Syck;

use Win32::OLE qw(in);
use Win32::OLE::Const;
use Win32::OLE::Variant;
use Win32::OLE::NLS qw(:LOCALE :DATE);
use Win32::OLE::Const 'Microsoft Excel';

use Path::Tiny;
use List::Util qw{sum};
use List::MoreUtils qw{natatime zip};
use Statistics::R;

use AlignDB::Util qw(:all);

$Win32::OLE::Warn = 2;    # die on errors...

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#

=head1 SYNOPSIS

    perl ofg_chart.pl -i Humanvsself.ofg.xlsx [options]
      Options:
        --help              -?      brief help message
        --regex_background  -rt STR 
        --regex_seperate    -rs STR 
        --filter_top        -ft INT filter by average Y values
        --filter_bottom     -fb INT filter by average Y values
        --style_red                 use red square instead of blue diamond
        --style_dot                 background lines with dots
=cut

# running options
my $file_input = 'Humanvsself.ofg.xlsx';

GetOptions(
    'help|?'    => sub { Getopt::Long::HelpMessage(0) },
    'input|i=s' => \$file_input,
    'x_lab|xl=s'            => \( my $x_lab            = "X" ),
    'y_lab|yl=s'            => \( my $y_lab            = "Y" ),
    'xrange|xr=s'           => \( my $xrange           = "A2:A17" ),
    'yrange|yr=s'           => \( my $yrange           = "F2:F17" ),
    'x_min=s'               => \( my $x_min            = 0 ),
    'x_max=s'               => \( my $x_max            = 15 ),
    'y_min=s'               => \( my $y_min            = 0.4 ),
    'y_max=s'               => \( my $y_max            = 0.6 ),
    'regex_background|rb=s' => \( my $regex_background = "ofg_tag" ),
    'regex_seperate|rs=s'   => \( my $regex_seperate   = "ofg_all" ),
    'mean_as_seperate|ms'   => \my $mean_as_seperate,
    'filter_top|ft=i'       => \( my $filter_top       = 0 ),
    'filter_bottom|fb=i'    => \( my $filter_bottom    = 0 ),
    'postfix=s'             => \( my $postfix          = "" ),
    'style_red'             => \my $style_red,
    'style_dot'             => \my $style_dot,
) or Getopt::Long::HelpMessage(1);

#----------------------------------------------------------#
# init
#----------------------------------------------------------#
$file_input = path($file_input)->absolute->stringify;

my $name_base = $file_input;
$name_base =~ s/\.xlsx?$//;
$name_base =~ s{\\}{\/}g;
my $range_base = "${xrange}_${yrange}";
$range_base =~ s/://g;
$range_base =~ s/[^\w]/_/g;
$name_base = "${name_base}_${range_base}";
$name_base .= ".$postfix" if $postfix;

my $file_csv = "$name_base.csv";
path($file_csv)->remove;

my $file_chart = "$name_base.pdf";
path($file_chart)->remove;

#----------------------------------------------------------#
# data from xlsx to csv
#----------------------------------------------------------#
{
    my $excel;    # excel object
    unless ( $excel = Win32::OLE->new("Excel.Application") ) {
        die "Cannot init Excel.Application\n";
    }
    my $workbook;
    unless ( $workbook = $excel->Workbooks->Open($file_input) ) {
        die "Cannot open xls file\n";
    }

    my @sheet_names       = sheet_names($workbook);
    my @sheets_background = grep {/$regex_background/} @sheet_names;
    my @sheets_seperate   = grep {/$regex_seperate/} @sheet_names;

    # store average Y values for filtering
    my %avg_y_of = map { $_ => 1 } @sheets_background;

    my @lines;    # output contents
    for my $sheetname ( @sheets_background, @sheets_seperate ) {
        printf "[sheet: %s]\n", $sheetname;
        my $sheet = $workbook->Worksheets($sheetname);

        printf "[range]\n";

        my @xs;
        for my $cell ( in $sheet->Range($xrange) ) {
            push @xs, $cell->{Value};
        }

        my @ys;
        for my $cell ( in $sheet->Range($yrange) ) {
            push @ys, $cell->{Value};
        }

        if ( @xs != @ys ) {
            warn "Unequal number for two columns\n";
        }

        my @groups = ( $avg_y_of{$sheetname} ? $sheetname : "seperate_$sheetname" ) x scalar(@xs);
        $avg_y_of{$sheetname} = mean(@ys);

        my @zips = zip @xs, @groups, @ys;

        my $it = natatime 3, @zips;
        while ( my @vals = $it->() ) {
            for (@vals) {
                $_ = '' if !defined $_;
            }
            push @lines, join( ",", @vals );
        }
    }
    $workbook->Close;
    $excel->Quit;

    # filtering
    @sheets_background
        = sort { $avg_y_of{$a} <=> $avg_y_of{$b} } @sheets_background;
    if ($filter_bottom) {
        print "Filtering bottom values by $filter_bottom\n";
        for my $i ( 0 .. $filter_bottom - 1 ) {
            @lines = grep { $_ !~ /\,$sheets_background[$i]\,/ } @lines;
        }
    }
    if ($filter_top) {
        print "Filtering top values by $filter_top\n";
        for my $i ( 1 .. $filter_top ) {
            @lines = grep { $_ !~ /\,$sheets_background[-$i]\,/ } @lines;
        }
    }

    # calc mean
    if ($mean_as_seperate) {
        my $ys_of_x = {};
        for (@lines) {
            my ( $x, undef, $y ) = split /,/;
            next if ( !defined $x or !defined $y );
            next if ( $x eq '' or $y eq '' );
            if ( !exists $ys_of_x->{$x} ) {
                $ys_of_x->{$x} = [$y];
            }
            else {
                push @{ $ys_of_x->{$x} }, $y;
            }
        }

        #print Dump $ys_of_x;

        for my $x ( sort { $a <=> $b } keys %{$ys_of_x} ) {
            my @ys   = @{ $ys_of_x->{$x} };
            my $mean = sum(@ys) / scalar @ys;
            push @lines, join( ",", ( $x, 'seperate_mean', $mean ) );
        }
    }

    open my $fh_csv, ">", $file_csv;
    print {$fh_csv} "X,group,Y\n";
    print {$fh_csv} "$_\n" for @lines;
    close $fh_csv;
}

{
    print "\nStart charting\n";
    my $R = Statistics::R->new;

    print "Passing variables\n";
    $R->set( 'file_csv',   $file_csv );
    $R->set( 'file_chart', $file_chart );
    $R->set( 'x_min',      $x_min );
    $R->set( 'x_max',      $x_max );
    $R->set( 'y_min',      $y_min );
    $R->set( 'y_max',      $y_max );

    # plotmath does not use curly brackets
    if ( $x_lab =~ /^(.+)(\{.+\})(.*)$/ ) {
        my $lab_pre  = $1;
        my $lab_exp  = $2;
        my $lab_post = $3;
        my $eval_code
            = qq{eval(parse( text = \"x_lab <- expression(paste(\\\"$lab_pre\\\", $lab_exp, \\\"$lab_post\\\"))\" ))};
        $R->run($eval_code);
    }
    else {
        $R->set( 'x_lab', $x_lab );
    }
    if ( $y_lab =~ /^(.+)(\{.+\})(.*)$/ ) {
        my $lab_pre  = $1;
        my $lab_exp  = $2;
        my $lab_post = $3;
        my $eval_code
            = qq{eval(parse( text = \"y_lab <- expression(paste(\\\"$lab_pre\\\", $lab_exp, \\\"$lab_post\\\"))\" ))};
        $R->run($eval_code);
    }
    else {
        $R->set( 'y_lab', $y_lab );
    }

    print "Run\n";

    # No newlines in the end of $r_code
    my $r_code = <<'EOF';
        library(ggplot2)
        library(scales)
        library(gridExtra)
        library(extrafont)
        
        # Ghostscript in %PATH%
        Sys.setenv(R_GSCMD = "gswin32c.exe")

        func_plot <- function (plotdata) {
            plot <- ggplot(data=plotdata, aes(x=X, y=Y, group=group)) +
                geom_line(colour="grey") +
                scale_x_continuous(labels = comma, limits=c(x_min, x_max)) + 
                scale_y_continuous(labels = comma, limits=c(y_min, y_max)) + 
                xlab(x_lab) + ylab(y_lab) + 
                theme_bw(base_size = 10) +
                guides(fill=FALSE) +
                theme(panel.grid.major.x = element_blank(), panel.grid.major.y = element_blank()) + 
                theme(panel.grid.minor.x = element_blank(), panel.grid.minor.y = element_blank())
            return(plot)
        }
        
        mydata <- read.csv(file_csv, header = TRUE)
        mydata$X <- as.numeric(mydata$X)
        rownames(mydata) <- NULL
        
        mydata_main <- subset(mydata, ! grepl("seperate", mydata$group))
        plot_main <- func_plot(mydata_main)
            
        
        mydata_sep <- subset(mydata, grepl("seperate", mydata$group))
        plot_sep <- func_plot(mydata_sep)
        plot_sep <- plot_sep + 
            geom_line(colour="blue", size = 0.5) + 
            geom_point(colour="blue", fill="blue", shape=23)
        
        pdf(file_chart, width = 6, height = 3, useDingbats=FALSE)
        grid.arrange(plot_main, plot_sep, ncol=2, nrow=1)
        dev.off()
        embed_fonts(file_chart)
EOF

    if ($style_red) {
        $r_code =~ s{fill\=\"blue\"}{fill\=\"white\"}g;
        $r_code =~ s{\=\"blue\"}{\=\"\#C0504D\"}g;
        $r_code =~ s{shape\=23}{shape\=22}g;
    }
    if ($style_dot) {
        $r_code
            =~ s{(func_plot\(mydata_main\))}{$1 + geom_point(colour="grey", fill="grey", shape=21, size=1)};
    }

    $R->run($r_code);
    print $R->result;

    print "Finish charting\n";
    print Dump $R->get('file_chart');
    $R->stop;
}

exit;

sub sheet_names {
    my $workbook = shift;

    my @sheet_names;
    for my $sheet ( in $workbook->Worksheets ) {
        push @sheet_names, $sheet->{Name};
    }

    return @sheet_names;
}

__END__
