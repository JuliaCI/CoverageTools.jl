using Pkg
Pkg.build()
Pkg.test("CoverageTools"; coverage=true)
