#Requires -Version 7.0
<#
.SYNOPSIS
    Recursively finds PDF pairs (name.pdf + name<Suffix>.pdf in the same folder)
    and, for each pair, reports whether they would produce identical printouts
    and a diff of their embedded text.

.DESCRIPTION
    "Identical printout" is determined by rasterizing each page at 150 DPI with
    pdftoppm and comparing SHA-256 hashes of the resulting PNGs. pdftoppm's PNG
    output is deterministic, so byte-identical rasters imply identical printed
    pages. Visually-similar-but-not-identical PDFs will report $false.

    Text diff is produced from `pdftotext -layout` output via Compare-Object.

    Requires poppler-utils on PATH: pdftoppm, pdftotext.

.PARAMETER Directory
    Root directory to search recursively.

.PARAMETER Suffix
    Suffix that appears immediately before ".pdf" on one file of each pair.
    e.g. if Suffix is "-signed", the script pairs "report.pdf" with
    "report-signed.pdf".

.PARAMETER ThrottleLimit
    Max parallel pair comparisons. Defaults to processor count.

.EXAMPLE
    ./Compare-PdfPairs.ps1 -Directory ./docs -Suffix '-signed'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$Suffix,
    [int]$ThrottleLimit = [Environment]::ProcessorCount
)

$ErrorActionPreference = 'Stop'

foreach ($tool in 'pdftoppm','pdftotext') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required tool '$tool' not found on PATH. Install poppler-utils."
    }
}

if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    throw "Directory not found: $Directory"
}
if ([string]::IsNullOrEmpty($Suffix)) {
    throw "Suffix must be non-empty."
}

# Find suffixed PDFs that have an un-suffixed sibling in the same folder.
Write-Progress -Id 0 -Activity 'Scanning for PDF pairs' -Status $Directory
$pairs = Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.pdf' |
    Where-Object {
        $_.BaseName.EndsWith($Suffix) -and $_.BaseName.Length -gt $Suffix.Length
    } |
    ForEach-Object {
        $base = $_.BaseName.Substring(0, $_.BaseName.Length - $Suffix.Length)
        $sibling = Join-Path $_.DirectoryName ($base + '.pdf')
        if (Test-Path -LiteralPath $sibling -PathType Leaf) {
            [pscustomobject]@{ Original = $sibling; Suffixed = $_.FullName }
        }
    }

Write-Progress -Id 0 -Activity 'Scanning for PDF pairs' -Completed

if (-not $pairs) {
    Write-Host "No pairs found under '$Directory' with suffix '$Suffix'."
    return
}

$total = @($pairs).Count
Write-Host "Comparing $total pair(s) with up to $ThrottleLimit in parallel..."

# Shared thread-safe counter for progress across parallel workers.
$counter = [int[]]::new(1)

$results = $pairs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $pair = $_
    $a = $pair.Original
    $b = $pair.Suffixed

    $counterRef = $using:counter
    $totalRef   = $using:total
    $workerId   = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    Write-Progress -Id $workerId -ParentId 0 `
        -Activity "Worker $workerId" `
        -Status ("Comparing " + [IO.Path]::GetFileName($a))

    $tmp  = Join-Path ([IO.Path]::GetTempPath()) ("pdfcmp_" + [Guid]::NewGuid())
    $dirA = Join-Path $tmp 'a'
    $dirB = Join-Path $tmp 'b'
    New-Item -ItemType Directory -Path $dirA,$dirB -Force | Out-Null

    try {
        # Rasterize + extract text for both files concurrently.
        $jobs = @(
            Start-ThreadJob -ScriptBlock {
                param($f,$d) & pdftoppm -r 150 -png $f (Join-Path $d 'page') 2>$null
            } -ArgumentList $a,$dirA
            Start-ThreadJob -ScriptBlock {
                param($f,$d) & pdftoppm -r 150 -png $f (Join-Path $d 'page') 2>$null
            } -ArgumentList $b,$dirB
            Start-ThreadJob -ScriptBlock {
                param($f,$o) & pdftotext -layout $f $o 2>$null
            } -ArgumentList $a,(Join-Path $tmp 'a.txt')
            Start-ThreadJob -ScriptBlock {
                param($f,$o) & pdftotext -layout $f $o 2>$null
            } -ArgumentList $b,(Join-Path $tmp 'b.txt')
        )
        $jobs | Wait-Job | Receive-Job | Out-Null
        $jobs | Remove-Job

        # Page-by-page raster comparison.
        $imgsA = Get-ChildItem -LiteralPath $dirA -Filter '*.png' | Sort-Object Name
        $imgsB = Get-ChildItem -LiteralPath $dirB -Filter '*.png' | Sort-Object Name

        $identical = $false
        if ($imgsA.Count -gt 0 -and $imgsA.Count -eq $imgsB.Count) {
            $identical = $true
            for ($i = 0; $i -lt $imgsA.Count; $i++) {
                $hA = (Get-FileHash -LiteralPath $imgsA[$i].FullName -Algorithm SHA256).Hash
                $hB = (Get-FileHash -LiteralPath $imgsB[$i].FullName -Algorithm SHA256).Hash
                if ($hA -ne $hB) { $identical = $false; break }
            }
        }

        # Text diff.
        $txtA = Join-Path $tmp 'a.txt'
        $txtB = Join-Path $tmp 'b.txt'
        $linesA = if (Test-Path -LiteralPath $txtA) { Get-Content -LiteralPath $txtA } else { @() }
        $linesB = if (Test-Path -LiteralPath $txtB) { Get-Content -LiteralPath $txtB } else { @() }

        $diffLines = Compare-Object -ReferenceObject $linesA -DifferenceObject $linesB |
            ForEach-Object {
                $marker = if ($_.SideIndicator -eq '<=') { '- ' } else { '+ ' }
                $marker + $_.InputObject
            }

        [pscustomobject]@{
            Original          = $a
            Suffixed          = $b
            PageCountA        = $imgsA.Count
            PageCountB        = $imgsB.Count
            IdenticalPrintout = $identical
            TextDiff          = if ($diffLines) { $diffLines -join [Environment]::NewLine }
                                else { '(no text differences)' }
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        $done = [System.Threading.Interlocked]::Increment([ref]$counterRef[0])
        Write-Progress -Id $workerId -Activity "Worker $workerId" -Completed
        Write-Progress -Id 0 -Activity 'Comparing PDF pairs' `
            -Status "$done / $totalRef complete" `
            -PercentComplete ([int](100 * $done / $totalRef))
    }
}

Write-Progress -Id 0 -Activity 'Comparing PDF pairs' -Completed

# Emit results (serial to keep output readable).
foreach ($r in $results) {
    Write-Host ('=' * 80)
    Write-Host "A: $($r.Original)"
    Write-Host "B: $($r.Suffixed)"
    Write-Host "Pages: $($r.PageCountA) vs $($r.PageCountB)"
    Write-Host "Identical printout: $($r.IdenticalPrintout)"
    Write-Host "Text diff:"
    Write-Host $r.TextDiff
}

# Also return the objects on the pipeline for downstream consumption.
$results
