# Copyright (c) 2024 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# repo: PaddleClas
# model: ppcls^configs^ImageNet^EfficientNet^EfficientNetB0
# api:paddle.nn.functional.pooling.adaptive_avg_pool2d||api:paddle.nn.functional.common.dropout||api:paddle.tensor.manipulation.squeeze||api:paddle.nn.functional.common.linear
import unittest

import numpy as np

import paddle


class LayerCase(paddle.nn.Layer):
    def __init__(self):
        super().__init__()
        self.parameter_0 = self.create_parameter(
            shape=[1280, 1000],
            dtype=paddle.float32,
        )
        self.parameter_1 = self.create_parameter(
            shape=[1000],
            dtype=paddle.float32,
        )

    def forward(
        self,
        var_0,  # (shape: [11, 1280, 7, 7], dtype: paddle.float32, stop_gradient: True)
    ):
        var_1 = paddle.nn.functional.pooling.adaptive_avg_pool2d(
            var_0, output_size=1, data_format='NCHW', name=None
        )
        var_2 = paddle.nn.functional.common.dropout(
            var_1,
            p=0.2,
            axis=None,
            training=True,
            mode='upscale_in_train',
            name=None,
        )
        var_3 = paddle.tensor.manipulation.squeeze(var_2, axis=[2, 3])
        var_4 = paddle.nn.functional.common.linear(
            x=var_3, weight=self.parameter_0, bias=self.parameter_1, name=None
        )
        return var_4


class TestLayer(unittest.TestCase):
    def setUp(self):
        self.inputs = (
            paddle.rand(shape=[11, 1280, 7, 7], dtype=paddle.float32),
        )
        self.net = LayerCase()

    def train(self, net, to_static, with_prim=False, with_cinn=False):
        if to_static:
            paddle.set_flags({'FLAGS_prim_all': with_prim})
            if with_cinn:
                build_strategy = paddle.static.BuildStrategy()
                build_strategy.build_cinn_pass = True
                net = paddle.jit.to_static(
                    net, build_strategy=build_strategy, full_graph=True
                )
            else:
                net = paddle.jit.to_static(net, full_graph=True)
        paddle.seed(123)
        outs = net(*self.inputs)
        return outs

    def test_ast_prim_cinn(self):
        st_out = self.train(self.net, to_static=True)
        cinn_out = self.train(
            self.net, to_static=True, with_prim=False, with_cinn=False
        )
        for st, cinn in zip(
            paddle.utils.flatten(st_out), paddle.utils.flatten(cinn_out)
        ):
            np.testing.assert_allclose(st.numpy(), cinn.numpy(), atol=1e-8)


if __name__ == '__main__':
    unittest.main()