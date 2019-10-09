using Pkg
Pkg.build()
Pkg.test("Coverage"; coverage=true)

using CoverageCore
cov_res = process_folder()
