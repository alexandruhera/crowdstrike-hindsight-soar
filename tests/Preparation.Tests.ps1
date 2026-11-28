Describe 'Fusion working directory preparation' {
    BeforeAll {
        $prepare = Join-Path (Split-Path $PSScriptRoot) '001-hindsight-preparation.ps1'
        function Invoke-Preparation($path) {
            & $prepare -json_input (@{ forensic_analysis_path = $path } | ConvertTo-Json) | ConvertFrom-Json
        }
    }
    It 'creates and accepts the supplied empty directory literally' {
        $path = Join-Path $TestDrive 'case[01]'
        (Invoke-Preparation $path).forensic_analysis_path | Should -Be $path
        (Invoke-Preparation $path).has_processing_errors | Should -BeFalse
        [IO.Directory]::Exists($path) | Should -BeTrue
    }
    It 'preserves evidence when the upstream path is already in use' {
        $path = [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'in-use')).FullName
        $file = Join-Path $path 'previous-run.jsonl'
        [IO.File]::WriteAllText($file, 'preserve me')
        (Invoke-Preparation $path).has_processing_errors | Should -BeTrue
        [IO.File]::ReadAllText($file) | Should -Be 'preserve me'
    }
    It 'rejects an existing file as the directory' {
        $path = Join-Path $TestDrive 'existing-file'
        [IO.File]::WriteAllText($path, 'original')
        (Invoke-Preparation $path).has_processing_errors | Should -BeTrue
        [IO.File]::ReadAllText($path) | Should -Be 'original'
    }
}
