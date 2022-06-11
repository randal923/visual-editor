import '../../delta/models/delta.model.dart';
import '../../delta/models/operation.model.dart';
import '../../documents/models/attribute-scope.enum.dart';
import '../../documents/models/attribute.model.dart';
import '../models/format-rule.model.dart';

/// Produces Delta with line-level attributes applied strictly to newline characters.
class ResolveLineFormatRule extends FormatRuleM {
  const ResolveLineFormatRule();

  @override
  DeltaM? applyRule(
    DeltaM document,
    int index, {
    int? len,
    Object? data,
    AttributeM? attribute,
  }) {
    if (attribute!.scope != AttributeScope.BLOCK) {
      return null;
    }

    // Apply line styles to all newline characters within range of this retain operation.
    var result = DeltaM()..retain(index);
    final itr = DeltaIterator(document)..skip(index);
    Operation op;

    for (var cur = 0; cur < len! && itr.hasNext; cur += op.length!) {
      op = itr.next(len - cur);
      final opText = op.data is String ? op.data as String : '';

      if (!opText.contains('\n')) {
        result.retain(op.length!);
        continue;
      }

      final delta = _applyAttribute(opText, op, attribute);
      result = result.concat(delta);
    }

    // And include extra newline after retain
    while (itr.hasNext) {
      op = itr.next();
      final opText = op.data is String ? op.data as String : '';
      final lf = opText.indexOf('\n');

      if (lf < 0) {
        result.retain(op.length!);
        continue;
      }

      final delta = _applyAttribute(opText, op, attribute, firstOnly: true);
      result = result.concat(delta);
      break;
    }

    return result;
  }

  DeltaM _applyAttribute(
    String text,
    Operation op,
    AttributeM attribute, {
    bool firstOnly = false,
  }) {
    final result = DeltaM();
    var offset = 0;
    var lf = text.indexOf('\n');
    final removedBlocks = _getRemovedBlocks(attribute, op);

    while (lf >= 0) {
      final actualStyle = attribute.toJson()..addEntries(removedBlocks);
      result
        ..retain(lf - offset)
        ..retain(1, actualStyle);

      if (firstOnly) {
        return result;
      }

      offset = lf + 1;
      lf = text.indexOf('\n', offset);
    }
    // Retain any remaining characters in text
    result.retain(text.length - offset);

    return result;
  }

  Iterable<MapEntry<String, dynamic>> _getRemovedBlocks(
    AttributeM<dynamic> attribute,
    Operation op,
  ) {
    // Enforce Block Format exclusivity by rule
    if (!AttributeM.exclusiveBlockKeys.contains(attribute.key)) {
      return <MapEntry<String, dynamic>>[];
    }

    return op.attributes?.keys
            .where((key) =>
                AttributeM.exclusiveBlockKeys.contains(key) &&
                attribute.key != key &&
                attribute.value != null)
            .map((key) => MapEntry<String, dynamic>(key, null)) ??
        [];
  }
}

/// Allows updating link format with collapsed selection.
class FormatLinkAtCaretPositionRule extends FormatRuleM {
  const FormatLinkAtCaretPositionRule();

  @override
  DeltaM? applyRule(
    DeltaM document,
    int index, {
    int? len,
    Object? data,
    AttributeM? attribute,
  }) {
    if (attribute!.key != AttributeM.link.key || len! > 0) {
      return null;
    }

    final delta = DeltaM();
    final itr = DeltaIterator(document);
    final before = itr.skip(index), after = itr.next();
    int? beg = index, retain = 0;

    if (before != null && before.hasAttribute(attribute.key)) {
      beg -= before.length!;
      retain = before.length;
    }

    if (after.hasAttribute(attribute.key)) {
      if (retain != null) retain += after.length!;
    }

    if (retain == 0) {
      return null;
    }

    delta
      ..retain(beg)
      ..retain(retain!, attribute.toJson());

    return delta;
  }
}

/// Produces Delta with inline-level attributes applied to all characters
/// except newlines.
class ResolveInlineFormatRule extends FormatRuleM {
  const ResolveInlineFormatRule();

  @override
  DeltaM? applyRule(
    DeltaM document,
    int index, {
    int? len,
    Object? data,
    AttributeM? attribute,
  }) {
    if (attribute!.scope != AttributeScope.INLINE) {
      return null;
    }

    final delta = DeltaM()..retain(index);
    final itr = DeltaIterator(document)..skip(index);
    Operation op;

    for (var cur = 0; cur < len! && itr.hasNext; cur += op.length!) {
      op = itr.next(len - cur);
      final text = op.data is String ? (op.data as String?)! : '';
      var lineBreak = text.indexOf('\n');

      if (lineBreak < 0) {
        delta.retain(op.length!, attribute.toJson());
        continue;
      }

      var pos = 0;

      while (lineBreak >= 0) {
        delta
          ..retain(lineBreak - pos, attribute.toJson())
          ..retain(1);
        pos = lineBreak + 1;
        lineBreak = text.indexOf('\n', pos);
      }

      if (pos < op.length!) {
        delta.retain(op.length! - pos, attribute.toJson());
      }
    }

    return delta;
  }
}

/// Produces Delta with attributes applied to image leaf node
class ResolveImageFormatRule extends FormatRuleM {
  const ResolveImageFormatRule();

  @override
  DeltaM? applyRule(
    DeltaM document,
    int index, {
    int? len,
    Object? data,
    AttributeM? attribute,
  }) {
    if (attribute == null || attribute.key != AttributeM.style.key) {
      return null;
    }

    assert(len == 1 && data == null);

    final delta = DeltaM()
      ..retain(index)
      ..retain(1, attribute.toJson());

    return delta;
  }
}
