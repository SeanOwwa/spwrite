/// Presentation layer: [CharacterPanelView], the right-hand sidebar that lists
/// an author's fictional characters for the open project.
///
/// It observes [CharacterPanelState] via `provider` and renders a scrollable
/// list of character cards. Each card shows the portrait (or a placeholder
/// avatar), the name and role, and a collapsed one-line summary; a "See more"
/// control expands the card inline to reveal the full notes so the author can
/// read without leaving the panel. Tapping the edit control opens the
/// [CharacterEditView] on a new screen. A header hosts the add-character (+)
/// control and a close button. All colors are drawn from [AppPalette].
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/character.dart';
import '../state/character_panel_state.dart';
import '../state/load_status.dart';
import '../theme/app_theme.dart';
import 'character_edit_view.dart';

/// The right-hand Character Panel sidebar. [onClose] hides the panel (the
/// enclosing editor owns the open/closed state).
class CharacterPanelView extends StatelessWidget {
  /// Invoked when the user taps the panel's close control.
  final VoidCallback onClose;

  const CharacterPanelView({super.key, required this.onClose});

  /// Creates a new character then opens it in the edit screen.
  Future<void> _addCharacter(
    BuildContext context,
    CharacterPanelState state,
  ) async {
    final Character? created = await state.createCharacter();
    if (created == null || !context.mounted) return;
    _openEditor(context, state, created);
  }

  /// Pushes the full-screen edit view for [character].
  void _openEditor(
    BuildContext context,
    CharacterPanelState state,
    Character character,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CharacterEditView(
          character: character,
          panelState: state,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CharacterPanelState state = context.watch<CharacterPanelState>();

    return Container(
      color: AppPalette.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(context, state),
          const Divider(height: 1, thickness: 1, color: AppPalette.outline),
          Expanded(child: _buildBody(context, state)),
        ],
      ),
    );
  }

  /// The panel header: a "Characters" title, an add (+) control, and a close
  /// control.
  Widget _buildHeader(BuildContext context, CharacterPanelState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      child: Row(
        children: <Widget>[
          const Icon(Icons.people_alt_outlined,
              size: 20, color: AppPalette.secondary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Characters',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Add character',
            icon: const Icon(Icons.add, color: AppPalette.primary),
            onPressed: () => _addCharacter(context, state),
          ),
          IconButton(
            tooltip: 'Close panel',
            icon: const Icon(Icons.close, color: AppPalette.textSecondary),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  /// The panel body: a loading indicator, an empty-state prompt, or the
  /// scrollable list of character cards.
  Widget _buildBody(BuildContext context, CharacterPanelState state) {
    if (state.status == LoadStatus.loading && state.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.people_outline,
                  size: 48, color: AppPalette.textSecondary),
              const SizedBox(height: 12),
              const Text(
                'No characters yet.\nAdd your cast to keep their details close '
                'while you write.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.textSecondary),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _addCharacter(context, state),
                icon: const Icon(Icons.add),
                label: const Text('Add character'),
              ),
            ],
          ),
        ),
      );
    }

    final List<Character> characters = state.characters;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: characters.length,
      itemBuilder: (BuildContext context, int index) {
        final Character character = characters[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _CharacterCard(
            character: character,
            onEdit: () => _openEditor(context, state, character),
          ),
        );
      },
    );
  }
}

/// A single character entry in the sidebar. Collapsed it shows the avatar,
/// name, role, and one-line summary; a "See more" control expands it inline to
/// reveal the full notes. On desktop/web a hover highlight hints interactivity.
class _CharacterCard extends StatefulWidget {
  final Character character;
  final VoidCallback onEdit;

  const _CharacterCard({required this.character, required this.onEdit});

  @override
  State<_CharacterCard> createState() => _CharacterCardState();
}

class _CharacterCardState extends State<_CharacterCard> {
  bool _expanded = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Character c = widget.character;
    final bool hasNotes = c.notes.trim().isNotEmpty;
    final bool hasSummary = c.summary.trim().isNotEmpty;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hovered ? AppPalette.surfaceVariant : AppPalette.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppPalette.outline),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildAvatar(c),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        c.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (c.role.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          c.role,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppPalette.secondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit character',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: AppPalette.textSecondary),
                  onPressed: widget.onEdit,
                ),
              ],
            ),
            if (hasSummary) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                c.summary,
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
            // Expanded notes ("see more" reveals the full free-form body).
            if (_expanded && hasNotes) ...<Widget>[
              const SizedBox(height: 10),
              const Divider(height: 1, color: AppPalette.outline),
              const SizedBox(height: 10),
              Text(
                c.notes,
                style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
            // "See more" / "See less" toggle, shown when there is more to read
            // than the collapsed view reveals.
            if (hasNotes || (hasSummary))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'See less' : 'See more'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The portrait avatar, or a placeholder icon when no image is set.
  Widget _buildAvatar(Character c) {
    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppPalette.surfaceVariant,
        shape: BoxShape.circle,
        border: Border.all(color: AppPalette.outline),
      ),
      child: c.image != null
          ? Image.memory(c.image!, fit: BoxFit.cover)
          : const Icon(Icons.person_outline,
              color: AppPalette.textSecondary, size: 24),
    );
  }
}
