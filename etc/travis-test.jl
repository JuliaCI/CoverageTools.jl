using Pkg
Pkg.build()
Pkg.test("CoverageCore"; coverage=true)
