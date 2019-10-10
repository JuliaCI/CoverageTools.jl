using Pkg
Pkg.build()
Pkg.test("CoverageCore"; coverage=true)

import CoverageCore
coveragecore_cov_res = CoverageCore.process_folder()

Pkg.add("Coverage")
import Coverage
coverage_cov_res = Coverage.process_folder()
# Coverage.Coveralls.submit(coverage_cov_res)
Coverage.Codecov.submit(coverage_cov_res)
