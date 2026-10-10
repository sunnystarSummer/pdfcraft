// The command registry, as the engine defines it.
//
// `crates/engine/src/commands.rs` is the single table behind menus, shortcuts, the palette and
// automation; `crates/ui-egui/src/commands.rs` is the egui shell's answer to "what does each id
// do here". This is the same answer for the Flutter shell. Nothing about the menu structure,
// the labels, the shortcuts or the enablement rules is restated in Dart — they are read from
// `command_list` so the two shells cannot drift.

import 'engine.dart';

/// One entry of the engine's command registry.
class Command {
  const Command({
    required this.id,
    required this.label,
    required this.enabled,
    this.menu,
    this.shortcut,
    this.tool,
  });

  factory Command.fromJson(Map<String, dynamic> json) => Command(
        id: json['id'] as String,
        label: json['label']?.toString() ?? '',
        enabled: json['enabled'] == true,
        menu: json['menu'] as String?,
        shortcut: json['shortcut'] as String?,
        tool: json['tool'] as String?,
      );

  final String id;
  final String label;
  final bool enabled;

  /// The menu this appears under, when it appears in one.
  final String? menu;
  final String? shortcut;

  /// The automation tool that performs this command, when one does.
  final String? tool;
}

/// The registry as the shell sees it, refreshed whenever enablement can have changed.
class CommandRegistry {
  CommandRegistry(this._commands);

  /// `doc` is the active document: enablement depends on it, and without it every command that
  /// needs a document reports disabled.
  factory CommandRegistry.load(Engine engine, {int? doc}) {
    final reply = engine.call('command_list', {'doc': ?doc});
    final list = (reply['commands'] as List?) ?? const [];
    return CommandRegistry(list.map((c) => Command.fromJson(c as Map<String, dynamic>)).toList(growable: false));
  }

  static const empty = CommandRegistry._empty();
  const CommandRegistry._empty() : _commands = const [];

  final List<Command> _commands;

  List<Command> get all => _commands;

  /// Menu titles in registry order, which is the order they are meant to be shown in.
  List<String> get menus {
    final seen = <String>[];
    for (final c in _commands) {
      final m = c.menu;
      if (m != null && !seen.contains(m)) seen.add(m);
    }
    return seen;
  }

  List<Command> inMenu(String menu) => _commands.where((c) => c.menu == menu).toList(growable: false);

  Command? byId(String id) {
    for (final c in _commands) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// What happened when a command ran. Reported rather than swallowed: a shell that silently does
/// nothing is indistinguishable from one that is broken.
enum CommandOutcome {
  /// The shell did it.
  done,

  /// No such id in the registry.
  unknown,

  /// The registry has it, but this shell does not implement it yet.
  unsupported,

  /// It ran and failed; the message says why.
  failed,
}

class CommandResult {
  const CommandResult(this.outcome, [this.message = '']);
  final CommandOutcome outcome;
  final String message;

  bool get ok => outcome == CommandOutcome.done;

  @override
  String toString() => message.isEmpty ? outcome.name : '${outcome.name}: $message';
}
