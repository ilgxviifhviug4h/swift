// RUN: not %target-swift-frontend(mock-sdk: %clang-importer-sdk) -disable-experimental-clang-importer-diagnostics -enable-objc-interop -typecheck %s 2>&1 | %FileCheck %s --strict-whitespace

// REQUIRES: objc_interop

import cfuncs
import ctypes
import IncompleteTypes

// CHECK-NOT: warning
// CHECK-NOT: error
// CHECK-NOT: note
let bar = Bar()
_ = bar.methodReturningForwardDeclaredInterface()
// CHECK: experimental_diagnostics_opt_out.swift:{{[0-9]+}}:{{[0-9]+}}: error: value of type 'Bar' has no member 'methodReturningForwardDeclaredInterface'
// CHECK-NOT: warning
// CHECK-NOT: error
// CHECK-NOT: note

// CHECK-NOT: warning
// CHECK-NOT: error
let s: PartialImport
s.c = 5
// CHECK: experimental_diagnostics_opt_out.swift:{{[0-9]+}}:{{[0-9]+}}: error: value of type 'PartialImport' has no member 'c'
// CHECK: ctypes.PartialImport:{{[0-9]+}}:{{[0-9]+}}: note: did you mean 'a'?
// CHECK: ctypes.PartialImport:{{[0-9]+}}:{{[0-9]+}}: note: did you mean 'b'?
// CHECK-NOT: warning
// CHECK-NOT: error
// CHECK-NOT: note

// CHECK-NOT: warning
// CHECK-NOT: error
unsupported_parameter_type(1,2)
// CHECK: experimental_diagnostics_opt_out.swift:{{[0-9]+}}:{{[0-9]+}}: error: cannot find 'unsupported_parameter_type' in scope
// CHECK-NOT: warning
// CHECK-NOT: error
// CHECK-NOT: note
