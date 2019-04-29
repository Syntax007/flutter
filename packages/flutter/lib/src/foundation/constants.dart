// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A constant that is true if the application was compiled in release mode.
///
/// More specifically, this is a constant that is true if the application was
/// compiled in Dart with the '-Ddart.vm.product=true' flag.
///
/// Since this is a const value, it can be used to indicate to the compiler that
/// a particular block of code will or will not be executed in release mode, and
/// hence can be removed.
const bool kReleaseMode = bool.fromEnvironment('dart.vm.product', defaultValue: false);

/// A constant that is true if the application was compiled in profile mode.
///
/// More specifically, this is a constant that is true if the application was
/// compiled in Dart with the '-Ddart.vm.profile=true' flag.
///
/// Since this is a const value, it can be used to indicate to the compiler that
/// a particular block of code will or will not be executed in profle mode, and
/// hence can be removed.
const bool kProfileMode = bool.fromEnvironment('dart.vm.profile', defaultValue: false);

/// A constant that is true if the application was compiled in debug mode.
///
/// More specifically, this is a constant that is true if the application was
/// not compiled with '-Ddart.vm.product=true' or '-Ddart.vm.profile=true'.
///
/// Since this is a const value, it can be used to indicate to the compiler that
/// a particular block of code will or will not be executed in debug mode, and
/// hence can be removed.
const bool kDebugMode = !kReleaseMode && !kProfileMode;
