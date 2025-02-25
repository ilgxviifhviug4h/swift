//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftRemoteMirror
import SymbolicationShims

class Inspector {
  let task: task_t
  let symbolicator: CSTypeRef
  let swiftCore: CSTypeRef
  let swiftConcurrency: CSTypeRef
  
  init?(pid: pid_t) {
    task = Self.findTask(pid, tryForkCorpse: false)
    if task == 0 { return nil }

    symbolicator = CSSymbolicatorCreateWithTask(task)
    swiftCore = CSSymbolicatorGetSymbolOwnerWithNameAtTime(
      symbolicator, "libswiftCore.dylib", kCSNow)
    swiftConcurrency = CSSymbolicatorGetSymbolOwnerWithNameAtTime(
      symbolicator, "libswift_Concurrency.dylib", kCSNow)
    _ = task_start_peeking(task)
  }
  
  deinit {
    task_stop_peeking(task)
    mach_port_deallocate(mach_task_self_, task)
  }

  func addReflectionInfoFromLoadedImages(context: SwiftReflectionContextRef) {
    _ = CSSymbolicatorForeachSymbolOwnerAtTime(symbolicator, kCSNow, { owner in
      let address = CSSymbolOwnerGetBaseAddress(owner);
      let _ = swift_reflection_addImage(context, address)
      })
  }

  static func findTask(_ pid: pid_t, tryForkCorpse: Bool) -> task_t {
    var task = task_t()
    var kr = task_for_pid(mach_task_self_, pid, &task)
    if kr != KERN_SUCCESS {
      print("Unable to get task for pid \(pid): \(machErrStr(kr))", to: &Std.err)
      return 0
    }

    if !tryForkCorpse {
      return task
    }
  
    var corpse = task_t()
    kr = task_generate_corpse(task, &corpse)
    if kr == KERN_SUCCESS {
      task_resume(task)
      mach_port_deallocate(mach_task_self_, task)
      return corpse
    } else {
      print("warning: unable to generate corpse for pid \(pid): \(machErrStr(kr))", to: &Std.err)
      return task
    }
  }
  
  func passContext() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(self).toOpaque()
  }
  
  func destroyContext() {
    Unmanaged.passUnretained(self).release()
  }
  
  func getAddr(symbolName: String) -> swift_addr_t {
    let fullName = "_" + symbolName
    var symbol = CSSymbolOwnerGetSymbolWithMangledName(swiftCore, fullName)
    if CSIsNull(symbol) {
      symbol = CSSymbolOwnerGetSymbolWithMangledName(swiftConcurrency, fullName)
    }
    let range = CSSymbolGetRange(symbol)
    return swift_addr_t(range.location)
  }

  func getSymbol(address: swift_addr_t) -> (name: String?, library: String?) {
    let symbol = CSSymbolicatorGetSymbolWithAddressAtTime(symbolicator, address,
                                                          kCSNow)
    return (CSSymbolGetName(symbol),
            CSSymbolOwnerGetName(CSSymbolGetSymbolOwner(symbol)))
  }

  func enumerateMallocs(callback: (swift_addr_t, UInt64) -> Void) {
    withoutActuallyEscaping(callback) {
      withUnsafePointer(to: $0) {
        task_enumerate_malloc_blocks(task, UnsafeMutableRawPointer(mutating: $0), CUnsignedInt(MALLOC_PTR_IN_USE_RANGE_TYPE), {
          (task, context, type, ranges, count) in
          let callback = context!.assumingMemoryBound(to: ((swift_addr_t, UInt64) -> Void).self).pointee
          for i in 0..<Int(count) {
            let range = ranges[i]
            callback(swift_addr_t(range.address), UInt64(range.size))
          }
        })
      }
    }
  }

  func read(address: swift_addr_t, size: Int) -> UnsafeRawPointer? {
    return task_peek(task, address, mach_vm_size_t(size))
  }

  func threadCurrentTasks() -> [(threadID: UInt64, currentTask: swift_addr_t)] {
    var threadList: UnsafeMutablePointer<thread_t>? = nil
    var threadCount: mach_msg_type_number_t = 0

    var kr = task_threads(task, &threadList, &threadCount)
    if kr != KERN_SUCCESS {
      print("Unable to gather threads of remote process: \(machErrStr(kr))")
      return []
    }

    defer {
      // Deallocate the port rights for the threads.
      for i in 0..<threadCount {
        mach_port_deallocate(mach_task_self_, threadList![Int(i)]);
      }

      // Deallocate the thread list.
      let ptr = vm_address_t(bitPattern: threadList)
      let size = vm_size_t(MemoryLayout<thread_t>.size) * vm_size_t(threadCount)
      vm_deallocate(mach_task_self_, ptr, size);
    }

    var results: [(threadID: UInt64, currentTask: swift_addr_t)] = []
    for i in 0..<threadCount {
      let THREAD_IDENTIFIER_INFO_COUNT = MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size
      var info = thread_identifier_info_data_t()
      var infoCount = mach_msg_type_number_t(THREAD_IDENTIFIER_INFO_COUNT)
      withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: THREAD_IDENTIFIER_INFO_COUNT) {
          kr = thread_info(threadList![Int(i)],
                           thread_flavor_t(THREAD_IDENTIFIER_INFO), $0,
                           &infoCount)
        }
      }
      if (kr != KERN_SUCCESS) {
        print("Unable to get info for thread \(i): \(machErrStr(kr))")
      } else {
        let tlsStart = info.thread_handle
        if tlsStart != 0 {
          let SWIFT_CONCURRENCY_TASK_KEY = 103
          let currentTaskPointer = tlsStart + UInt64(SWIFT_CONCURRENCY_TASK_KEY * MemoryLayout<UnsafeRawPointer>.size)
          if let ptr = read(address: currentTaskPointer, size: MemoryLayout<UnsafeRawPointer>.size) {
            let currentTask = ptr.load(as: UInt.self)
            results.append((threadID: info.thread_id, currentTask: swift_addr_t(currentTask)))
          }
        }
      }
    }
    return results
  }

  enum Callbacks {
    static let QueryDataLayout: @convention(c)
      (UnsafeMutableRawPointer?,
       DataLayoutQueryType,
       UnsafeMutableRawPointer?,
       UnsafeMutableRawPointer?) -> CInt
      = QueryDataLayoutFn
    
    static let Free: (@convention(c) (UnsafeMutableRawPointer?,
                                      UnsafeRawPointer?,
                                      UnsafeMutableRawPointer?) -> Void)? = nil
    
    static let ReadBytes: @convention(c)
      (UnsafeMutableRawPointer?,
       swift_addr_t,
       UInt64,
       UnsafeMutablePointer<UnsafeMutableRawPointer?>?) ->
       UnsafeRawPointer?
      = ReadBytesFn
    
    static let GetStringLength: @convention(c)
      (UnsafeMutableRawPointer?,
       swift_addr_t) -> UInt64
      = GetStringLengthFn
    
    static let GetSymbolAddress: @convention(c)
      (UnsafeMutableRawPointer?,
       UnsafePointer<CChar>?,
       UInt64) -> swift_addr_t
      = GetSymbolAddressFn
  }
}

private func instance(_ context: UnsafeMutableRawPointer?) -> Inspector {
  Unmanaged.fromOpaque(context!).takeUnretainedValue()
}

private func QueryDataLayoutFn(context: UnsafeMutableRawPointer?,
                              type: DataLayoutQueryType,
                              inBuffer: UnsafeMutableRawPointer?,
                              outBuffer: UnsafeMutableRawPointer?) -> CInt {
  let is64 = MemoryLayout<UnsafeRawPointer>.stride == 8

  switch type {
  case DLQ_GetPointerSize, DLQ_GetSizeSize:
    let size = UInt8(MemoryLayout<UnsafeRawPointer>.stride)
    outBuffer!.storeBytes(of: size, toByteOffset: 0, as: UInt8.self)
    return 1
  case DLQ_GetPtrAuthMask:
    let mask = GetPtrauthMask()
    outBuffer!.storeBytes(of: mask, toByteOffset: 0, as: UInt.self)
    return 1
  case DLQ_GetObjCReservedLowBits:
    var size: UInt8 = 0
#if os(macOS)
    // The low bit is reserved only on 64-bit macOS.
    if is64 {
      size = 1
    }
#endif
    outBuffer!.storeBytes(of: size, toByteOffset: 0, as: UInt8.self)
    return 1
  case DLQ_GetLeastValidPointerValue:
    var value: UInt64 = 0x1000
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    // 64-bit Apple platforms reserve the low 4GB.
    if is64 {
      value = 0x100000000
    }
#endif
    outBuffer!.storeBytes(of: value, toByteOffset: 0, as: UInt64.self)
    return 1
  default:
    return 0
  }
}

private func ReadBytesFn(
  context: UnsafeMutableRawPointer?,
  address: swift_addr_t,
  size: UInt64,
  outContext: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> UnsafeRawPointer? {
  task_peek(instance(context).task, address, size)
}

private func GetStringLengthFn(
  context: UnsafeMutableRawPointer?,
  address: swift_addr_t
) -> UInt64 {
  let maybeStr = task_peek_string(instance(context).task, address)
  guard let str = maybeStr else { return 0 }
  return UInt64(strlen(str))
}

private func GetSymbolAddressFn(
  context: UnsafeMutableRawPointer?,
  name: UnsafePointer<CChar>?,
  length: UInt64
) -> swift_addr_t {
  let nameStr: String = name!.withMemoryRebound(to: UInt8.self,
                                                capacity: Int(length)) {
    let buffer = UnsafeBufferPointer(start: $0, count: Int(length))
    return String(decoding: buffer, as: UTF8.self)
  }
  return instance(context).getAddr(symbolName: nameStr)
}
