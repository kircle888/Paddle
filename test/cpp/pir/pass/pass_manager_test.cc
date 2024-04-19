// Copyright (c) 2023 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <gtest/gtest.h>
#include "glog/logging.h"

// NOTE(zhangbo9674): File pd_op.h is generated by op_gen.py, see details in
// paddle/fluid/pir/dialect/CMakeLists.txt.
#include "paddle/fluid/pir/dialect/operator/interface/op_yaml_info.h"
#include "paddle/fluid/pir/dialect/operator/ir/op_dialect.h"
#include "paddle/fluid/pir/dialect/operator/ir/op_type.h"
#include "paddle/fluid/pir/dialect/operator/ir/pd_op.h"
#include "paddle/fluid/pir/dialect/operator/utils/utils.h"
#include "paddle/fluid/platform/errors.h"
#include "paddle/phi/core/enforce.h"
#include "paddle/phi/kernels/elementwise_add_kernel.h"
#include "paddle/pir/include/core/builtin_dialect.h"
#include "paddle/pir/include/core/builtin_op.h"
#include "paddle/pir/include/core/builtin_type.h"
#include "paddle/pir/include/core/dialect.h"
#include "paddle/pir/include/core/ir_context.h"
#include "paddle/pir/include/core/op_base.h"
#include "paddle/pir/include/core/operation.h"
#include "paddle/pir/include/pass/pass.h"
#include "paddle/pir/include/pass/pass_manager.h"
#include "test/cpp/pir/tools/macros_utils.h"

#ifndef _WIN32
class TestAnalysis1 {};
class TestAnalysis2 {};

IR_DECLARE_EXPLICIT_TEST_TYPE_ID(TestAnalysis1)
IR_DEFINE_EXPLICIT_TYPE_ID(TestAnalysis1)
IR_DECLARE_EXPLICIT_TEST_TYPE_ID(TestAnalysis2)
IR_DEFINE_EXPLICIT_TYPE_ID(TestAnalysis2)

TEST(pass_manager, PreservedAnalyses) {
  pir::detail::PreservedAnalyses pa;
  CHECK_EQ(pa.IsNone(), true);

  CHECK_EQ(pa.IsPreserved<TestAnalysis1>(), false);
  pa.Preserve<TestAnalysis1>();
  CHECK_EQ(pa.IsPreserved<TestAnalysis1>(), true);
  pa.Unpreserve<TestAnalysis1>();
  CHECK_EQ(pa.IsPreserved<TestAnalysis1>(), false);
  CHECK_EQ(pa.IsPreserved<TestAnalysis2>(), false);
  pa.Preserve<TestAnalysis1, TestAnalysis2>();
  CHECK_EQ(pa.IsPreserved<TestAnalysis1>(), true);
  CHECK_EQ(pa.IsPreserved<TestAnalysis2>(), true);
  CHECK_EQ(pa.IsAll(), false);
  pa.PreserveAll();
  CHECK_EQ(pa.IsAll(), true);
  CHECK_EQ(pa.IsNone(), false);
}
#endif

class AddOp : public pir::Op<AddOp> {
 public:
  using Op::Op;
  static const char *name() { return "test.add"; }
  static constexpr const char **attributes_name = nullptr;
  static constexpr uint32_t attributes_num = 0;
  void VerifySig();
  static void Build(pir::Builder &builder,             // NOLINT
                    pir::OperationArgument &argument,  // NOLINT
                    pir::Value l_operand,
                    pir::Value r_operand,
                    pir::Type sum_type);
};
void AddOp::VerifySig() {
  if (num_operands() != 2) {
    PADDLE_THROW(paddle::platform::errors::Fatal(
        "The size of inputs must be equal to 2."));
  }
  if (num_results() != 1) {
    PADDLE_THROW(paddle::platform::errors::Fatal(
        "The size of outputs must be equal to 1."));
  }
}
void AddOp::Build(pir::Builder &,
                  pir::OperationArgument &argument,
                  pir::Value l_operand,
                  pir::Value r_operand,
                  pir::Type sum_type) {
  argument.AddInput(l_operand);
  argument.AddInput(r_operand);
  argument.AddOutput(sum_type);
}
IR_DECLARE_EXPLICIT_TEST_TYPE_ID(AddOp)
IR_DEFINE_EXPLICIT_TYPE_ID(AddOp)

struct CountOpAnalysis {
  explicit CountOpAnalysis(pir::Operation *container_op) {
    PADDLE_ENFORCE_GT(
        container_op->num_regions(),
        0,
        phi::errors::InvalidArgument(
            "op must be a container with zero or multiple regions."));

    LOG(INFO) << "In CountOpAnalysis, op is " << container_op->name() << "\n";
    for (size_t i = 0; i < container_op->num_regions(); ++i) {
      auto &region = container_op->region(i);
      for (auto &block : region) {
        count += block.size();
      }
    }

    LOG(INFO) << "-- count is " << count << "\n";
  }

  int count = 0;
};

IR_DECLARE_EXPLICIT_TEST_TYPE_ID(CountOpAnalysis)
IR_DEFINE_EXPLICIT_TYPE_ID(CountOpAnalysis)

struct NoOperationAnalysis {
  int scale = 0;
};

IR_DECLARE_EXPLICIT_TEST_TYPE_ID(NoOperationAnalysis)
IR_DEFINE_EXPLICIT_TYPE_ID(NoOperationAnalysis)

class TestPass : public pir::Pass {
 public:
  TestPass() : pir::Pass("TestPass", 1) {}
  void Run(pir::Operation *op) override {
    auto count_op_analysis = analysis_manager().GetAnalysis<CountOpAnalysis>();
    pass_state().preserved_analyses.Preserve<CountOpAnalysis>();
    CHECK_EQ(pass_state().preserved_analyses.IsPreserved<CountOpAnalysis>(),
             true);
    auto no_operation_analysis =
        analysis_manager().GetAnalysis<NoOperationAnalysis>();
    pass_state().preserved_analyses.Preserve<NoOperationAnalysis>();
    CHECK_EQ(pass_state().preserved_analyses.IsPreserved<NoOperationAnalysis>(),
             true);
    CHECK_EQ(count_op_analysis.count, 11);
    no_operation_analysis.scale = 8;
    CHECK_EQ(no_operation_analysis.scale, 8);

    auto module_op = op->dyn_cast<pir::ModuleOp>();
    CHECK_EQ(module_op.operation(), op);
    CHECK_EQ(module_op.name(), module_op->name());
    LOG(INFO) << "In " << pass_info().name << ": " << module_op->name()
              << std::endl;

    pass_state().preserved_analyses.Unpreserve<CountOpAnalysis>();
    CHECK_EQ(pass_state().preserved_analyses.IsPreserved<CountOpAnalysis>(),
             false);
    pass_state().preserved_analyses.Unpreserve<NoOperationAnalysis>();
    CHECK_EQ(pass_state().preserved_analyses.IsPreserved<NoOperationAnalysis>(),
             false);
  }

  bool CanApplyOn(pir::Operation *op) const override {
    return op->isa<::pir::ModuleOp>() && op->num_regions() > 0;
  }
};

void BuildProgram(pir::Builder &builder) {  // NOLINT
  paddle::dialect::FullOp full_input_op =
      builder.Build<paddle::dialect::FullOp>(std::vector<int64_t>{4, 3, 16, 16},
                                             1.5,
                                             phi::DataType::FLOAT32,
                                             phi::CPUPlace());

  paddle::dialect::FullOp full_filter_op =
      builder.Build<paddle::dialect::FullOp>(std::vector<int64_t>{64, 3, 3, 3},
                                             1.5,
                                             phi::DataType::FLOAT32,
                                             phi::CPUPlace());

  paddle::dialect::FullOp full_mean_op = builder.Build<paddle::dialect::FullOp>(
      std::vector<int64_t>{64}, 1.5, phi::DataType::FLOAT32, phi::CPUPlace());

  paddle::dialect::FullOp full_variance_op =
      builder.Build<paddle::dialect::FullOp>(std::vector<int64_t>{64},
                                             1.5,
                                             phi::DataType::FLOAT32,
                                             phi::CPUPlace());

  paddle::dialect::FullOp full_scale_op =
      builder.Build<paddle::dialect::FullOp>(std::vector<int64_t>{64},
                                             1.5,
                                             phi::DataType::FLOAT32,
                                             phi::CPUPlace());

  paddle::dialect::FullOp full_bias_op = builder.Build<paddle::dialect::FullOp>(
      std::vector<int64_t>{64}, 1.5, phi::DataType::FLOAT32, phi::CPUPlace());

  paddle::dialect::Conv2dOp conv2d_op =
      builder.Build<paddle::dialect::Conv2dOp>(full_input_op.out(),
                                               full_filter_op.out());

  paddle::dialect::BatchNormOp batch_norm_op =
      builder.Build<paddle::dialect::BatchNormOp>(conv2d_op.out(),
                                                  full_mean_op.out(),
                                                  full_variance_op.out(),
                                                  full_scale_op.out(),
                                                  full_bias_op.out(),
                                                  true,
                                                  0.9,
                                                  1e-6,
                                                  "NCHW",
                                                  false,
                                                  false);

  auto transpose1_op = builder.Build<paddle::dialect::TransposeOp>(
      batch_norm_op.out(), std::vector<int>{0, 2, 3, 1});

  auto transpose2_op = builder.Build<paddle::dialect::TransposeOp>(
      transpose1_op.out(), std::vector<int>{0, 3, 1, 2});

  builder.Build<paddle::dialect::FetchOp>(transpose2_op.out(), "out", 0);
}

TEST(pass_manager, PassManager) {
  pir::IrContext *ctx = pir::IrContext::Instance();
  ctx->GetOrRegisterDialect<paddle::dialect::OperatorDialect>();
  pir::Program program(ctx);
  pir::Builder builder = pir::Builder(ctx, program.block());
  BuildProgram(builder);

  EXPECT_EQ(program.block()->size(), 11u);

  // (9) Test pass manager for program.
  pir::PassManager pm(ctx);

  pm.AddPass(std::make_unique<TestPass>());

  // pm.EnableIRPrinting();
  pm.EnableIRPrinting(std::make_unique<pir::PassManager::IRPrinterOption>(
      [](pir::Pass *pass, pir::Operation *op) {
        return pass->name() == "TestPass";
      },
      [](pir::Pass *pass, pir::Operation *op) {
        return pass->name() == "TestPass";
      },
      true,
      true));

  // pm.EnablePassTiming(true);

  CHECK_EQ(pm.Run(&program), true);
}
