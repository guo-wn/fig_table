#!/usr/bin/perl
use strict;
use warnings;
use autodie;

use Getopt::Long;
use FindBin;
use YAML qw(Dump Load DumpFile LoadFile);

use Win32::OLE qw(in);
use Win32::OLE::Const;
use Win32::OLE::Variant;
use Win32::OLE::NLS qw(:LOCALE :DATE);
use Win32::OLE::Const 'Microsoft Excel';

#use Win32::OLE::Const 'Corel - CorelDRAW';
use Win32::OLE::Const 'Corel - CorelDRAW 15.0 Type Library';

$Win32::OLE::Warn = 2;    # die on errors...

use Path::Tiny;
use Set::Scalar;

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#

=head1 SYNOPSIS

Don't work under CorelDraw X7. Use X6 or below.

    perl corel_fig.pl -i Fig.S1.yaml

=cut

GetOptions(
    'help|?' => sub { Getopt::Long::HelpMessage(0) },
    'input|i=s' => \( my $file_yaml = 'Fig.S1.yaml' ),
) or Getopt::Long::HelpMessage(1);

#----------------------------------------------------------#
# init
#----------------------------------------------------------#
# The structure of yaml file:
# filename:sheetname:chart_serial:[x, y] coordinates
my $dispatch = LoadFile($file_yaml);
my $charts   = $dispatch->{charts};
my $ranges   = $dispatch->{ranges};
my $files    = $dispatch->{files};
my $texts    = $dispatch->{texts};
my $x_unit   = $dispatch->{unit}{x} || 50;
my $y_unit   = $dispatch->{unit}{y} || 45;

# Excel files should be located in the same dir as the yaml file.
# cdr file will be named after yaml file.
$file_yaml = path($file_yaml)->absolute;
my $base_dir = $file_yaml->parent->stringify;
my $cfile    = $file_yaml->stringify;
$cfile =~ s/\.ya?ml$/\.cdr/;

my $excel;    # excel object
unless ( $excel = Win32::OLE->new("Excel.Application") ) {
    die "Cannot init Excel.Application\n";
}

my $cda;      # CorelDraw Application object
unless ( $cda = Win32::OLE->new("CorelDRAW.Application") ) {
    die "Cannot init CorelDRAW.Application\n";
}

my $cs = $cda->CorelScript;    # CorelScript object
while ( $cs->IsDocument ) {    #Close all currently open documents
    $cs->FileClose(0);
}
$cs->FileNew;

my $doc   = $cda->{ActiveDocument};    # corel document object
my $layer = $cda->{ActiveLayer};

#----------------------------#
# Change page settings
#----------------------------#
$doc->{Unit}           = cdrMillimeter;
$doc->{ReferencePoint} = cdrTopLeft;      # selected shape's topleft

# A4 210 * 297 mm
$cda->{ActivePage}->SetSize( 210, 297 );
$doc->{DrawingOriginX} = -105 + 5;
$doc->{DrawingOriginY} = 148.5 - 5;       # give space for texts

#----------------------------------------------------------#
# Paste every charts
#----------------------------------------------------------#
for my $filename ( sort keys %{$charts} ) {
    printf "[file: %s]\n", $filename;

    # open xls file
    my $efile = path( $base_dir, $filename )->stringify;
    if ( !-e $efile ) {
        warn "File not exists: $efile\n";
        next;
    }
    my $workbook;
    unless ( $workbook = $excel->Workbooks->Open($efile) ) {
        die "Cannot open xls file\n";
    }
    my @sheet_names;
    for my $sheet ( in $workbook->Worksheets ) {
        push @sheet_names, $sheet->{Name};
    }
    my $name_set = Set::Scalar->new(@sheet_names);
    for my $sheetname ( sort keys %{ $charts->{$filename} } ) {
        printf "[sheet: %s]\n", $sheetname;
        if ( !$name_set->has($sheetname) ) {
            print " " x 4, "sheet not exists!\n";
            next;
        }
        my $sheet = $workbook->Worksheets($sheetname);
        for my $chart_serial ( keys %{ $charts->{$filename}{$sheetname} } ) {
            printf "[chart: %s]\n", $chart_serial;

            # Must do this for unknown reasons
            $sheet->ChartObjects($chart_serial)->Activate;

            # copy & paste
            $sheet->ChartObjects($chart_serial)->Copy;
            sleep 1;

            my ( $x, $y )
                = @{ $charts->{$filename}{$sheetname}{$chart_serial} };
            $layer->PasteSpecial("Enhanced Metafile");
            sleep 1;

            # move the shape
            # leave some spaces
            my $selection = $cda->{ActiveSelection};
            $selection->SetSize( $x_unit * 0.95, $y_unit * 0.95 );
            $selection->SetPosition( $x * $x_unit, -$y * $y_unit );
            sleep 1;
        }
    }
    $workbook->Close;
}

#----------------------------------------------------------#
# Paste every ranges
#----------------------------------------------------------#
for my $filename ( sort keys %{$ranges} ) {
    printf "[file: %s]\n", $filename;

    # open xls file
    my $efile = path( $base_dir, $filename )->stringify;
    if ( !-e $efile ) {
        warn "File not exists: $efile\n";
        next;
    }
    my $workbook;
    unless ( $workbook = $excel->Workbooks->Open($efile) ) {
        die "Cannot open xls file\n";
    }
    my @sheet_names;
    for my $sheet ( in $workbook->Worksheets ) {
        push @sheet_names, $sheet->{Name};
    }
    my $name_set = Set::Scalar->new(@sheet_names);
    for my $sheetname ( sort keys %{ $ranges->{$filename} } ) {
        printf "[sheet: %s]\n", $sheetname;
        if ( !$name_set->has($sheetname) ) {
            print " " x 4, "sheet not exists!\n";
            next;
        }
        my $sheet = $workbook->Worksheets($sheetname);
        for my $range ( @{ $ranges->{$filename}{$sheetname} } ) {
            printf "[range]\n";

            my ( $x, $y ) = @{ $range->{pos} };
            my $font = $range->{font} || "Arial";
            my $size = $range->{size} || 16;
            my $bold   = $range->{bold}   ? cdrTrue : cdrUndefined;
            my $italic = $range->{italic} ? cdrTrue : cdrUndefined;
            my $rotate = $range->{rotate};
            my $sprintf = $range->{sprintf};

            # text
            my $text = $sheet->Range( $range->{copy} )->Value;
            $text = sprintf $sprintf, $text if defined $sprintf;
            $layer->CreateArtisticText( 0, 0, $text, cdrLanguageNone,
                cdrCharSetMixed, $font, $size, $bold, $italic );

            my $selection = $cda->{ActiveSelection};
            if ($rotate) {
                $selection->Rotate($rotate);
            }
            $selection->SetPosition( $x * $x_unit, -$y * $y_unit );
        }
    }
    $workbook->Close;
}

## not working
##----------------------------------------------------------#
## Import every figure files
##----------------------------------------------------------#
#for my $i ( @{$files} ) {
#    my $name = $i->{name};
#    my ( $x, $y ) = @{ $i->{pos} };
#
#    printf "[file: %s]\n", $name;
#
#    my $ffile = path( $base_dir, $name )->absolute->stringify;
#    if ( !-e $ffile ) {
#        warn "File not exists: $ffile\n";
#        next;
#    }
#
#    $layer->Import({FileName  => $ffile, Filter => cdrAutoSense });
#    sleep 1;
#
#    # move the figure
#    # leave some spaces
#    my $selection = $cda->{ActiveSelection};
#    $selection->SetSize( $x_unit * 0.95, $y_unit * 0.95 );
#    $selection->SetPosition( $x * $x_unit, -$y * $y_unit );
#    sleep 1;
#}

#----------------------------------------------------------#
# Write every texts
#----------------------------------------------------------#
for my $i ( @{$texts} ) {
    my $text = $i->{text};
    my ( $x, $y ) = @{ $i->{pos} };
    my $font = $i->{font} || "Arial";
    my $size = $i->{size} || 16;
    my $bold   = $i->{bold}   ? cdrTrue : cdrUndefined;
    my $italic = $i->{italic} ? cdrTrue : cdrUndefined;
    my $rotate = $i->{rotate};

    printf "[text: %s]\n", $text;

    #Layer.CreateArtisticText
    #Function CreateArtisticText(Left As Double, Bottom As Double, Text As
    #String, [LanguageID As cdrTextLanguage = cdrLanguageNone], [CharSet As
    #cdrTextCharSet = cdrCharSetMixed], [Font As String], [Size As Single],
    #[Bold As cdrTriState = cdrUndefined], [Italic As cdrTriState =
    #cdrUndefined], [Underline As cdrFontLine = cdrMixedFontLine]), [Alignment
    #As cdrAlignment = cdrMixedAlignment]) As Shape
    $layer->CreateArtisticText( 0, 0, $text, cdrLanguageNone, cdrCharSetMixed,
        $font, $size, $bold, $italic );

    my $selection = $cda->{ActiveSelection};
    if ($rotate) {
        $selection->Rotate($rotate);
    }
    $selection->SetPosition( $x * $x_unit, -$y * $y_unit );
}

#----------------------------------------------------------#
# Cleanup and Save
#----------------------------------------------------------#
$cs->ZoomToWidth;

$cs->FileSave( $cfile, 800, 0, 0, 0 );
$cs->FileClose;

$excel->Quit;
$cda->Quit;

__END__
