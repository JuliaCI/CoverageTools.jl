using Pkg
Pkg.build()
Pkg.test("CoverageCore"; coverage=true)

using CoverageCore
cov_res = process_folder()
