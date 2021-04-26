# Copyright (c) 2018 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.


def CheckChangeOnUpload(input_api, output_api):
  results = []
  results += input_api.RunTests(
                 input_api.canned_checks.CheckLucicfgGenOutput(input_api,
                                                               output_api,
                                                               'main.star')
             )
  results += input_api.RunTests(
                 input_api.canned_checks.CheckChangedLUCIConfigs(input_api,
                                                                 output_api)
             )
  return results
