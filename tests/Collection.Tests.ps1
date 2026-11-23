Describe 'Fusion collection attempts' {
    BeforeAll {
        $collector = Join-Path (Split-Path $PSScriptRoot) '001-hindsight-collection.ps1'
        function Invoke-Collection {
            & $collector -json_input ($request | ConvertTo-Json) | ConvertFrom-Json
        }
        function Write-Marker($path, $id, $status) {
            [IO.File]::WriteAllText("$path.status.json", (@{
                run_id = $id
                status = $status
                message = 'fixture outcome'
            } | ConvertTo-Json))
        }
    }
    BeforeEach {
        $folder = [IO.Directory]::CreateDirectory((Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        $id = [guid]::NewGuid().ToString('N')
        $file = Join-Path $folder "Default-$id.jsonl"
        $request = @{
            run_id = $id
            system_hostname = 'host'
            selected_browser = 'Google Chrome'
            analysis_timestamp = '2026-11-21T23-30'
            forensic_analysis_path = $folder
            forensic_results = @($file)
        }
    }
    It 'returns pending for a partly written file' {
        [IO.File]::WriteAllText($file, 'first chunk')
        $r = Invoke-Collection
        $r.collection_status | Should -Be 'pending'
        $r.has_processing_errors | Should -BeTrue
        $r.zip_file_path | Should -BeNullOrEmpty
        @(Get-ChildItem $folder -Filter '*.zip').Count | Should -Be 0
    }
    It 'surfaces a failed profile even if another profile is pending' {
        $other = Join-Path $folder "Profile-2-$id.jsonl"
        $request.forensic_results += $other
        Write-Marker $other $id 'failed'
        $r = Invoke-Collection
        $r.collection_status | Should -Be 'failed'
        $r.exception_messages -join ' ' | Should -Match 'fixture outcome'
    }
    It 'returns a readable ZIP only after every profile is ready, and reuses it on retry' {
        $other = Join-Path $folder "Profile-2-$id.jsonl"
        $request.forensic_results += $other
        [IO.File]::WriteAllText($file, 'completed result')
        [IO.File]::WriteAllText($other, 'other result')
        Write-Marker $file $id 'ready'
        (Invoke-Collection).collection_status | Should -Be 'pending'
        Write-Marker $other $id 'ready'
        $r = Invoke-Collection
        $r.collection_status | Should -Be 'ready'
        $r.has_processing_errors | Should -BeFalse
        $zip = [IO.Compression.ZipFile]::OpenRead($r.zip_file_path)
        try {
            $zip.Entries.Count | Should -Be 2
            $entry = $zip.GetEntry([IO.Path]::GetFileName($file))
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $reader.ReadToEnd() | Should -Be 'completed result' } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
        $when = (Get-Item -LiteralPath $r.zip_file_path).LastWriteTimeUtc
        (Invoke-Collection).zip_file_path | Should -Be $r.zip_file_path
        (Get-Item -LiteralPath $r.zip_file_path).LastWriteTimeUtc | Should -Be $when
    }
    It 'rejects a ready marker from another execution' {
        [IO.File]::WriteAllText($file, 'old result')
        Write-Marker $file ([guid]::NewGuid().ToString('N')) 'ready'
        (Invoke-Collection).collection_status | Should -Be 'failed'
    }
    It 'rejects a ready marker whose file is missing' {
        Write-Marker $file $id 'ready'
        (Invoke-Collection).collection_status | Should -Be 'failed'
    }
    It 'rejects in-flight requests that omit the run ID' {
        $request.Remove('run_id')
        $r = Invoke-Collection
        $r.collection_status | Should -Be 'failed'
        $r.exception_messages -join ' ' | Should -Match 'run_id'
    }
    It 'rejects results outside the upstream directory' {
        $outside = Join-Path $TestDrive "outside-$id.jsonl"
        [IO.File]::WriteAllText($outside, 'outside')
        Write-Marker $outside $id 'ready'
        $request.forensic_results = @($outside)
        (Invoke-Collection).collection_status | Should -Be 'failed'
    }
    It 'rejects an archive that was corrupted after publication' {
        [IO.File]::WriteAllText($file, 'evidence')
        Write-Marker $file $id 'ready'
        $r = Invoke-Collection
        $r.collection_status | Should -Be 'ready'
        [IO.File]::WriteAllText($r.zip_file_path, 'broken zip')
        $next = Invoke-Collection
        $next.collection_status | Should -Be 'failed'
        $next.zip_file_path | Should -BeNullOrEmpty
    }
    It 'rejects a substituted ZIP entry of the same name and length' {
        [IO.File]::WriteAllText($file, 'original')
        Write-Marker $file $id 'ready'
        $published = Invoke-Collection
        $published.collection_status | Should -Be 'ready'
        $zip = [IO.Compression.ZipFile]::Open($published.zip_file_path, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry = $zip.GetEntry([IO.Path]::GetFileName($file))
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::ASCII.GetBytes('tampered')
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        $r = Invoke-Collection
        $r.collection_status | Should -Be 'failed'
        $r.has_processing_errors | Should -BeTrue
        $r.zip_file_path | Should -BeNullOrEmpty
    }
    It 'reports compression failure with no published ZIP or staging file' {
        [IO.File]::WriteAllText($file, 'evidence')
        Write-Marker $file $id 'ready'
        $exclusive = [IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
        try { $r = Invoke-Collection } finally { $exclusive.Dispose() }
        $r.collection_status | Should -Be 'failed'
        $r.has_processing_errors | Should -BeTrue
        $r.zip_file_path | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $folder -Include '*.zip','*.tmp' -Recurse).Count | Should -Be 0
    }
}
