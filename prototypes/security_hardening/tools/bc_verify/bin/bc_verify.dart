// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// REFERENCE bytecode verifier (Linux only, not shipped, not a security boundary on the device).
//
// Purpose: design and validate the verification rules that the engine patch
// (engine_patch/0001-dart-bytecode-verifier.patch) enforces inside the Dart VM, using the pinned
// upstream dart2bytecode tables (Opcode, BytecodeFormats, instructionSize, isWideOpcode) and the
// upstream module reader (Component.read). Every valid module must pass; the malformed corpus is
// used to check rejections. The device relies only on the in-VM verifier.
//
//   dart --packages=<dart-src>/.dart_tool/package_config.json bc_verify.dart <module.bc>...
// Prints one line per module: "OK <file> functions=N instructions=M" or
// "REJECT <file> <function> pc=<n>: <reason>". Exit code 1 if any module is rejected.

import 'dart:io';

import 'package:dart2bytecode/bytecode_serialization.dart' show BufferedReader, LinkReader;
import 'package:dart2bytecode/constant_pool.dart';
import 'package:dart2bytecode/dbc.dart';
import 'package:dart2bytecode/declarations.dart';
import 'package:dart2bytecode/exceptions.dart';

class Reject implements Exception {
  Reject(this.pc, this.reason);
  final int pc;
  final String reason;
}

/// Constants mirrored from the pinned VM (runtime/vm/stack_frame_kbc.h, constants_kbc.h).
const kParamEndSlotFromFp = 4;
const kSpecialIndexCount = 2;
const kMaxStackDepth = 4096;

/// Fixed stack effects (pops, pushes) of public opcodes, derived from runtime/vm/interpreter.cc
/// at Dart 416e33b. Opcodes with operand-dependent effects are handled in [effect].
const Map<String, (int, int)> fixedEffects = {
  'kDup': (1, 2), 'kCheckStack': (0, 0), 'kNop': (0, 0), 'kCheckFunctionTypeArgs': (0, 0),
  'kInstantiateType': (2, 1), 'kInstantiateTypeArgumentsTOS': (2, 1), 'kDrop1': (1, 0),
  'kLoadConstant': (0, 0), 'kPushConstant': (0, 1), 'kPushNull': (0, 1), 'kPushTrue': (0, 1),
  'kPushFalse': (0, 1), 'kPushInt': (0, 1), 'kPush': (0, 1), 'kStoreLocal': (1, 1),
  'kPopLocal': (1, 0), 'kMoveSpecial': (0, 0), 'kBooleanNegateTOS': (1, 1), 'kInitLateField': (1, 0),
  'kPushUninitializedSentinel': (0, 1), 'kStoreStaticTOS': (1, 0), 'kLoadStatic': (0, 1),
  'kStoreFieldTOS': (2, 0), 'kStoreContextParent': (2, 0), 'kStoreContextVar': (2, 0),
  'kLoadFieldTOS': (1, 1), 'kLoadTypeArgumentsField': (1, 1), 'kLoadContextParent': (1, 1),
  'kLoadContextVar': (1, 1), 'kLoadRecordField': (1, 1), 'kAllocateContext': (0, 1),
  'kCloneContext': (1, 1), 'kAllocate': (0, 1), 'kAllocateT': (2, 1), 'kCreateArrayTOS': (2, 1),
  'kAssertAssignable': (5, 1), 'kAssertSubtype': (5, 0), 'kJump': (0, 0), 'kJumpIfNoAsserts': (0, 0),
  'kJumpIfNotZeroTypeArgs': (0, 0), 'kJumpIfUnchecked': (0, 0), 'kJumpIfEqStrict': (2, 0),
  'kJumpIfNeStrict': (2, 0), 'kJumpIfTrue': (1, 0), 'kJumpIfFalse': (1, 0), 'kJumpIfNull': (1, 0),
  'kJumpIfNotNull': (1, 0), 'kJumpIfInitialized': (1, 0), 'kSuspend': (0, 0), 'kStoreIndexedTOS': (3, 0),
  'kEqualsNull': (1, 1), 'kNullCheck': (1, 0), 'kNegateInt': (1, 1), 'kAddInt': (2, 1),
  'kSubInt': (2, 1), 'kMulInt': (2, 1), 'kTruncDivInt': (2, 1), 'kModInt': (2, 1), 'kBitAndInt': (2, 1),
  'kBitOrInt': (2, 1), 'kBitXorInt': (2, 1), 'kShlInt': (2, 1), 'kShrInt': (2, 1),
  'kCompareIntEq': (2, 1), 'kCompareIntGt': (2, 1), 'kCompareIntLt': (2, 1), 'kCompareIntGe': (2, 1),
  'kCompareIntLe': (2, 1), 'kNegateDouble': (1, 1), 'kAddDouble': (2, 1), 'kSubDouble': (2, 1),
  'kMulDouble': (2, 1), 'kDivDouble': (2, 1), 'kCompareDoubleEq': (2, 1), 'kCompareDoubleGt': (2, 1),
  'kCompareDoubleLt': (2, 1), 'kCompareDoubleGe': (2, 1), 'kCompareDoubleLe': (2, 1),
  'kAllocateClosure': (0, 1), 'kLoadClosureElement': (1, 1), 'kStoreClosureElement': (2, 0),
  'kReturnTOS': (1, 0), 'kThrow': (0, 0), 'kSetFrame': (0, 0), 'kFrame': (0, 0),
  'kEntry': (0, 0), 'kEntryOptional': (0, 0), 'kEntrySuspendable': (0, 0), 'kAllocateRecord': (0, 0),
};

/// Opcodes a module must never contain.
const forbidden = {
  'kTrap': 'Trap instruction',
  'kExternalCall': 'native (external) call',
  'kFfiCall': 'FFI call (unsupported in interpreted modules)',
  // Dart 3.14 and later (FFI native-function resolution).
  'kResolveNativeFunction': 'FFI native function resolution (unsupported in interpreted modules)',
  'kRecordCoverage': 'coverage instrumentation',
};

class Insn {
  Insn(this.pc, this.opcode, this.wide, this.ops, this.length);
  final int pc;
  final Opcode opcode;
  final bool wide;
  final List<int> ops;
  final int length;
  String get name => opcode.toString().split('.').last;
}

List<Insn> decodeAll(List<int> b) {
  final out = <Insn>[];
  var pc = 0;
  while (pc < b.length) {
    final byte = b[pc];
    if (byte >= Opcode.values.length) throw Reject(pc, 'invalid opcode byte $byte');
    var op = Opcode.values[byte];
    final wide = isWideOpcode(op);
    if (wide) op = fromWideOpcode(op);
    final fmt = BytecodeFormats[op];
    if (fmt == null) throw Reject(pc, 'reserved or VM-internal opcode ${op.name} (byte $byte)');
    final len = instructionSize(fmt.encoding, wide);
    if (pc + len > b.length) throw Reject(pc, 'truncated instruction ${op.name}');
    int u32(int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
    final ops = switch (fmt.encoding) {
      Encoding.k0 => <int>[],
      Encoding.kA => [b[pc + 1]],
      Encoding.kD => [wide ? u32(pc + 1) : b[pc + 1]],
      Encoding.kX => [wide ? u32(pc + 1).toSigned(32) : b[pc + 1].toSigned(8)],
      Encoding.kT => [wide ? (b[pc + 1] | (b[pc + 2] << 8) | (b[pc + 3] << 16)).toSigned(24) : b[pc + 1].toSigned(8)],
      Encoding.kAE => [b[pc + 1], wide ? u32(pc + 2) : b[pc + 2]],
      Encoding.kAY => [b[pc + 1], wide ? u32(pc + 2).toSigned(32) : b[pc + 2].toSigned(8)],
      Encoding.kDF => wide ? [u32(pc + 1), b[pc + 5]] : [b[pc + 1], b[pc + 2]],
      Encoding.kABC => [b[pc + 1], b[pc + 2], b[pc + 3]],
    };
    out.add(Insn(pc, op, wide, ops, len));
    pc += len;
  }
  return out;
}

/// "ArgDesc num-args 3, num-type-args 0, names [...]" -> size including the type-args vector.
int argDescSize(Object? handle) {
  final m = RegExp(r'num-args (\d+), num-type-args (\d+)').firstMatch('$handle');
  if (m == null) throw StateError('not an argument descriptor: $handle');
  return int.parse(m.group(1)!) + (int.parse(m.group(2)!) > 0 ? 1 : 0);
}

void verifyCode(List<int> bytecodes, ExceptionsTable exc, ConstantPool pool, int numParams, String where,
    void Function(int) count) {
  final insns = decodeAll(bytecodes);
  count(insns.length);
  final byPc = {for (var i = 0; i < insns.length; i++) insns[i].pc: i};
  final entries = pool.entries;
  if (insns.isEmpty) throw Reject(0, 'empty function body');
  final first = insns.first.name;
  if (!const {'kEntry', 'kEntryOptional', 'kEntrySuspendable'}.contains(first)) {
    throw Reject(0, 'function does not start with an Entry instruction ($first)');
  }

  ConstantPoolEntry lit(Insn i, int index, String want, bool Function(ConstantPoolEntry) ok) {
    if (index < 0 || index >= entries.length) throw Reject(i.pc, '${i.name}: pool index $index out of range (${entries.length})');
    final e = entries[index];
    if (!ok(e)) throw Reject(i.pc, '${i.name}: pool[$index] is ${e.runtimeType}, expected $want');
    return e;
  }

  // 1. Frame and prologue, with the interpreter's exact semantics (interpreter.cc Entry,
  //    EntryOptional, EntrySuspendable, CopyParameters, Frame):
  //    Entry D: depth = D. EntryOptional A,B,C: depth = A + B + C (reserved = 0).
  //    EntrySuspendable A,B,C: depth = 1 + A + B + C (reserved suspend-state slot FP[0]).
  //    CopyParameters consumes B LoadConstant (reg == reserved + A + i) or C pairs of LoadConstant
  //    (same reg); those are never executed as instructions. Then an optional Frame D adds D.
  final e0 = insns.first;
  var frameSize = 0;
  var bodyStart = 1; // index of the first instruction executed after the prologue
  final hasSuspendState = e0.name == 'kEntrySuspendable';
  final prologueRegs = <int>{};
  if (e0.name == 'kEntry') {
    frameSize = e0.ops[0];
  } else {
    final reserved = hasSuspendState ? 1 : 0;
    final (a, b, c) = (e0.ops[0], e0.ops[1], e0.ops[2]);
    if (b != 0 && c != 0) throw Reject(0, 'both optional positional and named parameters');
    frameSize = reserved + a + b + c;
    var k = 1;
    for (var j = 0; j < b; j++, k++) {
      if (k >= insns.length || insns[k].name != 'kLoadConstant') throw Reject(0, 'prologue: missing default value LoadConstant');
      if (insns[k].ops[0] != reserved + a + j) throw Reject(insns[k].pc, 'prologue: default value stored to register ${insns[k].ops[0]}');
      prologueRegs.add(insns[k].ops[0]);
    }
    for (var j = 0; j < c; j++, k += 2) {
      if (k + 1 >= insns.length || insns[k].name != 'kLoadConstant' || insns[k + 1].name != 'kLoadConstant') {
        throw Reject(0, 'prologue: missing named parameter LoadConstant pair');
      }
      if (insns[k].ops[0] != insns[k + 1].ops[0]) throw Reject(insns[k].pc, 'prologue: named pair uses two registers');
      prologueRegs.add(insns[k].ops[0]);
    }
    bodyStart = k;
    if (k < insns.length && insns[k].name == 'kFrame') {
      frameSize += insns[k].ops[0];
      bodyStart = k + 1;
    }
  }
  for (final r in prologueRegs) {
    if (r < 0 || r >= frameSize) throw Reject(0, 'prologue register $r outside the frame ($frameSize)');
  }

  void reg(Insn i, int r, {bool signed = false}) {
    final ok = signed ? (r < frameSize && r >= -(kParamEndSlotFromFp + numParams + 1)) : (r >= 0 && r < frameSize);
    if (!ok) throw Reject(i.pc, '${i.name}: register $r outside the frame (size $frameSize, params $numParams)');
  }

  int target(Insn i) {
    final t = i.pc + i.ops[0];
    if (!byPc.containsKey(t)) throw Reject(i.pc, '${i.name}: jump target $t is not an instruction boundary');
    return t;
  }

  // 2. Per-instruction operand checks (references, registers, forbidden opcodes).
  final recordFields = <int, int>{};
  for (final i in insns) {
    final n = i.name;
    if (forbidden.containsKey(n)) throw Reject(i.pc, 'forbidden opcode: ${forbidden[n]}');
    if (!fixedEffects.containsKey(n) &&
        !const {'kDirectCall', 'kUncheckedDirectCall', 'kInterfaceCall', 'kInstantiatedInterfaceCall',
          'kUncheckedInterfaceCall', 'kDynamicCall', 'kUncheckedClosureCall'}.contains(n)) {
      throw Reject(i.pc, 'opcode ${i.name} is not supported by the verifier');
    }
    final fmt = BytecodeFormats[i.opcode]!;
    for (var k = 0; k < fmt.operands.length && k < i.ops.length; k++) {
      switch (fmt.operands[k]) {
        case Operand.reg:
          reg(i, i.ops[k]);
        case Operand.xeg:
          reg(i, i.ops[k], signed: true);
        case Operand.tgt:
          target(i);
        default:
          break;
      }
    }
    switch (n) {
      case 'kDirectCall' || 'kUncheckedDirectCall':
        final e = lit(i, i.ops[0], 'DirectCall', (e) => e is ConstantDirectCall) as ConstantDirectCall;
        if (argDescSize(e.argDesc) != i.ops[1]) throw Reject(i.pc, '${i.name}: argument count ${i.ops[1]} != descriptor ${argDescSize(e.argDesc)}');
      case 'kInterfaceCall' || 'kUncheckedInterfaceCall':
        final e = lit(i, i.ops[0], 'InterfaceCall', (e) => e is ConstantInterfaceCall) as ConstantInterfaceCall;
        if (argDescSize(e.argDesc) != i.ops[1]) throw Reject(i.pc, '${i.name}: argument count mismatch');
      case 'kInstantiatedInterfaceCall':
        final e = lit(i, i.ops[0], 'InstantiatedInterfaceCall', (e) => e is ConstantInstantiatedInterfaceCall)
            as ConstantInstantiatedInterfaceCall;
        if (argDescSize(e.argDesc) != i.ops[1]) throw Reject(i.pc, '${i.name}: argument count mismatch');
      case 'kDynamicCall':
        final e = lit(i, i.ops[0], 'DynamicCall', (e) => e is ConstantDynamicCall) as ConstantDynamicCall;
        if (argDescSize(e.argDesc) != i.ops[1]) throw Reject(i.pc, '${i.name}: argument count mismatch');
      case 'kUncheckedClosureCall':
        final e = lit(i, i.ops[0], 'ObjectRef(ArgDesc)', (e) => e is ConstantObjectRef);
        if (argDescSize((e as ConstantObjectRef).object) != i.ops[1]) throw Reject(i.pc, '${i.name}: argument count mismatch');
      case 'kAllocate':
        lit(i, i.ops[0], 'Class', (e) => e is ConstantClass);
      case 'kAllocateClosure':
        lit(i, i.ops[0], 'AllocateClosure', (e) => e is ConstantAllocateClosure);
      case 'kLoadStatic' || 'kStoreStaticTOS':
        lit(i, i.ops[0], 'StaticField', (e) => e is ConstantStaticField);
      case 'kLoadFieldTOS' || 'kStoreFieldTOS' || 'kInitLateField':
        lit(i, i.ops[0], 'InstanceField', (e) => e is ConstantInstanceField);
      case 'kLoadTypeArgumentsField':
        lit(i, i.ops[0], 'TypeArgumentsField', (e) => e is ConstantTypeArgumentsField);
      case 'kInstantiateType':
        lit(i, i.ops[0], 'Type', (e) => e is ConstantType);
      case 'kInstantiateTypeArgumentsTOS':
        lit(i, i.ops[1], 'ObjectRef(TypeArguments)', (e) => e is ConstantObjectRef);
      case 'kAssertAssignable':
        lit(i, i.ops[1], 'SubtypeTestCache', (e) => e is ConstantSubtypeTestCache);
      case 'kPushConstant' || 'kNullCheck':
        lit(i, i.ops[0], 'tagged object', taggedObject);
      case 'kLoadConstant':
        lit(i, i.ops[1], 'tagged object', taggedObject);
      case 'kAllocateRecord':
        final e = lit(i, i.ops[0], 'Type(RecordType)', (e) => e is ConstantType && '${e.type}'.startsWith('RecordType('));
        recordFields[i.pc] = recordFieldCount('${(e as ConstantType).type}');
      case 'kMoveSpecial':
        if (i.ops[0] >= kSpecialIndexCount) throw Reject(i.pc, 'MoveSpecial: special index ${i.ops[0]} out of range');
      case 'kThrow':
        if (i.ops[0] > 1) throw Reject(i.pc, 'Throw: invalid kind ${i.ops[0]}');
      case 'kSuspend':
        if (!hasSuspendState) throw Reject(i.pc, 'Suspend outside a suspendable function');
      case 'kEntry' || 'kEntryOptional' || 'kEntrySuspendable':
        if (i.pc != 0) throw Reject(i.pc, '${i.name} not at the start of the function');
      default:
        break;
    }
  }

  // 3. Exception handlers: ranges and handler targets on instruction boundaries; handlers start
  //    with SetFrame (the interpreter's SP is reset there).
  final handlerStarts = <int>{};
  for (final t in exc.blocks) {
    if (t.startPC < 0 || t.endPC > bytecodes.length || t.startPC > t.endPC) throw Reject(t.startPC, 'invalid try range');
    if (!byPc.containsKey(t.handlerPC)) throw Reject(t.handlerPC, 'handler is not an instruction boundary');
    if (insns[byPc[t.handlerPC]!].name != 'kSetFrame') throw Reject(t.handlerPC, 'handler does not start with SetFrame');
    for (final ti in t.types) {
      if (ti < 0 || ti >= entries.length) throw Reject(t.handlerPC, 'handler type index out of range');
    }
    handlerStarts.add(t.handlerPC);
  }

  // 4. Stack-depth dataflow (depth = number of slots from FP, as SP - FP + 1). Memory-safety
  //    floor: no instruction may read below the lowest legitimate frame level, i.e. min(frame size,
  //    any SetFrame operand) (async handlers restore one slot below the prologue frame); a SetFrame
  //    operand must lie inside the frame.
  var floor = frameSize;
  for (final i in insns) {
    if (i.name == 'kSetFrame') {
      if (i.ops[0] > frameSize) throw Reject(i.pc, 'SetFrame ${i.ops[0]} beyond the frame ($frameSize)');
      if (i.ops[0] < floor) floor = i.ops[0];
    }
  }
  // Interval dataflow: depth in [lo, hi] at each instruction (paths join with min/max; the real
  // interpreter can reach a merge point with different SP, e.g. async handlers). Every pop is
  // checked against lo (memory safety: never read below the floor); growth is capped by hi.
  final lo = <int, int>{};
  final hi = <int, int>{};
  final work = <int>[];
  void flow(int pc, int l, int h, int from) {
    if (l < floor) throw Reject(from, 'stack underflow into the frame (depth $l < $floor)');
    if (h > frameSize + kMaxStackDepth) throw Reject(from, 'stack depth $h exceeds the limit');
    final ol = lo[pc], oh = hi[pc];
    final nl = ol == null ? l : (l < ol ? l : ol);
    final nh = oh == null ? h : (h > oh ? h : oh);
    if (ol != nl || oh != nh) {
      lo[pc] = nl;
      hi[pc] = nh;
      work.add(pc);
    }
  }

  // The prologue establishes the frame; execution starts after it. Handlers start at SetFrame.
  if (bodyStart >= insns.length) throw Reject(0, 'function has no body after the prologue');
  flow(insns[bodyStart].pc, frameSize, frameSize, 0);
  for (final h in handlerStarts) {
    final next = byPc[h]! + 1;
    if (next >= insns.length) throw Reject(h, 'handler has no body');
    final d = insns[byPc[h]!].ops[0];
    flow(insns[next].pc, d, d, h);
  }

  while (work.isNotEmpty) {
    final pc = work.removeLast();
    final idx = byPc[pc]!;
    final i = insns[idx];
    final n = i.name;
    int pops, pushes;
    if (const {'kDirectCall', 'kUncheckedDirectCall', 'kInterfaceCall', 'kInstantiatedInterfaceCall',
      'kUncheckedInterfaceCall', 'kDynamicCall'}.contains(n)) {
      (pops, pushes) = (i.ops[1], 1);
    } else if (n == 'kUncheckedClosureCall') {
      (pops, pushes) = (i.ops[1] + 1, 1);
    } else if (n == 'kAllocateRecord') {
      (pops, pushes) = (recordFields[pc]!, 1);
    } else if (n == 'kThrow') {
      (pops, pushes) = (i.ops[0] == 0 ? 1 : 2, 0);
    } else {
      (pops, pushes) = fixedEffects[n]!;
    }
    if (n == 'kFrame' || n == 'kEntry' || n == 'kEntryOptional' || n == 'kEntrySuspendable') {
      throw Reject(pc, '${i.name} outside the function prologue');
    }
    var l = lo[pc]!, h = hi[pc]!;
    if (n == 'kSetFrame') {
      l = i.ops[0];
      h = i.ops[0];
    }
    if (l - pops < floor) throw Reject(pc, '${i.name} pops $pops but only ${l - floor} values may be on the stack');
    l = l - pops + pushes;
    h = h - pops + pushes;
    final terminal = n == 'kReturnTOS' || n == 'kThrow' || n == 'kJump';
    if (fmtIsJump(i)) {
      final t = target(i);
      // Suspend: the target is the resume point; the resumed value is pushed on resumption.
      flow(t, n == 'kSuspend' ? l + 1 : l, n == 'kSuspend' ? h + 1 : h, pc);
    }
    if (!terminal) {
      if (idx + 1 >= insns.length) throw Reject(pc, 'execution falls off the end of the function');
      flow(insns[idx + 1].pc, l, h, pc);
    }
  }
}


/// Pool slots holding raw native pointers (never valid as Dart objects).
/// Compared by tag name so the same source builds against Dart 3.13 (`kFfiCall`) and Dart 3.14,
/// where that entry was renamed `kNativeFunction`.
bool taggedObject(ConstantPoolEntry e) =>
    !const {'kExternalCall', 'kFfiCall', 'kNativeFunction'}.contains(e.tag.name);

/// Number of fields of "RecordType(a, b, T c)": top-level commas only (generics nest).
int recordFieldCount(String t) {
  final body = t.substring(t.indexOf('(') + 1, t.lastIndexOf(')'));
  if (body.trim().isEmpty) return 0;
  var depth = 0, count = 1;
  for (final ch in body.split('')) {
    if (ch == '<' || ch == '(' || ch == '[' || ch == '{') depth++;
    if (ch == '>' || ch == ')' || ch == ']' || ch == '}') depth--;
    if (ch == ',' && depth == 0) count++;
  }
  return count;
}

bool fmtIsJump(Insn i) => BytecodeFormats[i.opcode]!.encoding == Encoding.kT;

void main(List<String> args) {
  var failed = 0;
  for (final path in args) {
    var functions = 0, instructions = 0;
    try {
      final component = Component.read(BufferedReader(LinkReader(), File(path).readAsBytesSync()));
      for (final lib in component.libraries) {
        for (final cls in lib.classes) {
          for (final f in cls.members.functions) {
            final code = f.code;
            if (code == null) continue;
            final isStatic = (f.flags & FunctionDeclaration.isStaticFlag) != 0;
            final where = '${cls.name}.${f.name}';
            functions++;
            try {
              verifyCode(code.bytecodes, code.exceptionsTable, code.constantPool,
                  f.parameters.length + (isStatic ? 0 : 1), where, (n) => instructions += n);
              for (final c in code.closures) {
                functions++;
                final cc = c.code!;
                try {
                  verifyCode(cc.bytecodes, cc.exceptionsTable, code.constantPool, c.parameters.length + 1,
                      '$where.<closure ${c.name}>', (n) => instructions += n);
                } on Reject catch (r) {
                  throw Reject(r.pc, '[closure ${c.name}] ${r.reason}');
                }
              }
            } on Reject catch (r) {
              print('REJECT $path $where pc=${r.pc}: ${r.reason}');
              failed++;
              throw const _Done();
            }
          }
          for (final fd in cls.members.fields) {
            final code = fd.initializerCode;
            if (code == null) continue;
            functions++;
            try {
              verifyCode(code.bytecodes, code.exceptionsTable, code.constantPool, 0, '${cls.name}.${fd.name}<init>',
                  (n) => instructions += n);
            } on Reject catch (r) {
              print('REJECT $path ${cls.name}.${fd.name}<init> pc=${r.pc}: ${r.reason}');
              failed++;
              throw const _Done();
            }
          }
        }
      }
      print('OK $path functions=$functions instructions=$instructions');
    } on _Done {
      // already reported
    } catch (e) {
      print('REJECT $path <reader>: ${e.toString().split('\n').first}');
      failed++;
    }
  }
  exitCode = failed > 0 ? 1 : 0;
}

class _Done implements Exception {
  const _Done();
}
