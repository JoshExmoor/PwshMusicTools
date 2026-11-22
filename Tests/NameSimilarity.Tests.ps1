BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Get-NormalizedName' {
    It 'lower-cases, strips punctuation and collapses whitespace' {
        InModuleScope PwshMusicTools {
            Get-NormalizedName -Name '  AC/DC -  Back   In Black! ' | Should -Be 'acdc back in black'
        }
    }

    It 'keeps digits' {
        InModuleScope PwshMusicTools {
            Get-NormalizedName -Name 'CD1' | Should -Be 'cd1'
        }
    }

    It 'returns an empty string for an empty name' {
        InModuleScope PwshMusicTools {
            Get-NormalizedName -Name '' | Should -Be ''
        }
    }
}

Describe 'Get-NameSimilarity' {
    It 'scores identical names 1' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'Kid A' -B 'Kid A' | Should -Be 1
        }
    }

    It 'scores two empty strings 1' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A '' -B '' | Should -Be 1
        }
    }

    It 'scores one empty string 0' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A '' -B 'Kid A' | Should -Be 0
            Get-NameSimilarity -A 'Kid A' -B '' | Should -Be 0
        }
    }

    It 'ignores case' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'Kid A' -B 'KID A' | Should -Be 1
        }
    }

    It 'ignores punctuation' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'AC/DC' -B 'ACDC' | Should -Be 1
            Get-NameSimilarity -A 'R.E.M.' -B 'REM' | Should -Be 1
        }
    }

    It 'collapses whitespace' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'Kid   A' -B ' Kid A ' | Should -Be 1
        }
    }

    It 'keeps digits significant' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'CD1' -B 'CD2' | Should -BeLessThan 1
            Get-NameSimilarity -A 'Disc 1' -B 'Disc 2' | Should -BeLessThan 1
        }
    }

    It 'scores a known near miss' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'Radiohead' -B 'Radiohed' | Should -BeExactly (1 - 1 / 9)
        }
    }

    It 'scores clearly different names below 0.5' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A 'Kid A' -B 'OK Computer' | Should -BeLessThan 0.5
        }
    }

    It 'does not treat different punctuation-only names as equal' {
        InModuleScope PwshMusicTools {
            Get-NameSimilarity -A '...' -B '!!!' | Should -Be 0
            Get-NameSimilarity -A '...' -B '...' | Should -Be 1
        }
    }
}
