[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Target,
    [double] $TargetI = -11,
    [double] $TargetTP = -1
)

$ErrorActionPreference = 'Stop'
$audioExtensions = @(
    '.wav', '.flac', '.mp3', '.m4a', '.aac', '.ogg', '.oga',
    '.opus', '.wma', '.aiff', '.aif', '.ape', '.mka', '.webm'
)

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw 'ffmpeg was not found in PATH.'
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw 'ffprobe was not found in PATH.'
}

function Test-AudioFile {
    param([System.IO.FileInfo] $File)
    return $audioExtensions -contains $File.Extension.ToLowerInvariant()
}

function Invoke-Normalize {
    param(
        [System.IO.FileInfo] $InputFile,
        [string] $OutputPath
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Write-Host "Skipping existing output: $OutputPath"
        return
    }

    Write-Host "Measuring: $($InputFile.FullName)"
    $pass1Arguments = @(
        '-hide_banner', '-nostdin', '-i', $InputFile.FullName,
        '-af', "loudnorm=I=$TargetI`:TP=$TargetTP`:LRA=50`:linear=false`:print_format=json",
        '-f', 'null', '-'
    )
    $rawStats = (& ffmpeg @pass1Arguments 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Measurement failed: $($InputFile.FullName)"
        return
    }

    $jsonStart = $rawStats.IndexOf('{')
    $jsonEnd = $rawStats.LastIndexOf('}')
    if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) {
        Write-Warning "Measurement JSON was not found: $($InputFile.FullName)"
        return
    }

    $measurement = $rawStats.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
    $measuredI = [double]$measurement.input_i
    $measuredLra = [double]$measurement.input_lra
    $measuredTp = [double]$measurement.input_tp
    $measuredThresh = [double]$measurement.input_thresh
    $offset = [double]$measurement.target_offset
    $targetLra = [Math]::Max(1.0, $measuredLra)
    $predictedTp = $measuredTp + $TargetI - $measuredI
    $sampleRate = ((& ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 $InputFile.FullName) | Select-Object -First 1).Trim()

    if ([string]::IsNullOrWhiteSpace($sampleRate)) {
        Write-Warning "Input sample rate was not found: $($InputFile.FullName)"
        return
    }


    Write-Host "Normalizing linearly: $($InputFile.FullName) -> $OutputPath"
    $filter = "loudnorm=I=$TargetI`:TP=$TargetTP`:LRA=$targetLra`:measured_I=$measuredI`:measured_LRA=$measuredLra`:measured_TP=$measuredTp`:measured_thresh=$measuredThresh`:offset=$offset`:linear=true`:print_format=summary"
    $pass2Arguments = @(
        '-hide_banner', '-nostdin', '-i', $InputFile.FullName,
        '-af', $filter,
        '-ar', $sampleRate, '-c:a', 'pcm_s24le', '-n', $OutputPath
    )
    & ffmpeg @pass2Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Normalization failed: $($InputFile.FullName)"
    }
}

if (Test-Path -LiteralPath $Target -PathType Leaf) {
    $inputFile = Get-Item -LiteralPath $Target
    if (-not (Test-AudioFile $inputFile)) {
        throw "Unsupported audio extension: $($inputFile.Extension)"
    }
    $outputPath = "$($inputFile.DirectoryName)/$($inputFile.BaseName)_normalized.wav"
    Invoke-Normalize -InputFile $inputFile -OutputPath $outputPath
    exit 0
}

if (Test-Path -LiteralPath $Target -PathType Container) {
    $directory = Get-Item -LiteralPath $Target
    $outputDirectory = "$($directory.FullName)/normalized"
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $directory.FullName -File | Where-Object {
        (Test-AudioFile $_) -and ($_.Name -notlike '*_normalized.wav')
    })

    foreach ($inputFile in $files) {
        $outputPath = "$outputDirectory/$($inputFile.BaseName)_normalized.wav"
        Invoke-Normalize -InputFile $inputFile -OutputPath $outputPath
    }
    if ($files.Count -eq 0) {
        Write-Host "No supported audio files found in $($directory.FullName)."
    }
    exit 0
}

throw "Input file or directory not found: $Target"
