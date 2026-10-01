/// Presentation layer: [CharacterPanelView], the right-hand sidebar that lists
/// an author's fictional characters for the open project.
///
/// It observes [CharacterPanelState] via `provider` and renders a scrollable
/// list of character cards. Each card shows the portrait (or a placeholder
/// avatar), the name and role, and the details truncated to a short preview; a
/// "See more" control expands the card inline to reveal the full details so the
/// author can read without leaving the panel. Tapping the edit control opens the
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
import 'panel_header.dart';

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
          Expanded(child: _buildBody(context, state)),
        ],
      ),
    );
  }

  /// The panel header: a "Characters" title, an add (+) control, and a close
  /// control.
  Widget _buildHeader(BuildContext context, CharacterPanelState state) {
    final int count = state.characters.length;
    return PanelHeader(
      icon: Icons.people_alt_outlined,
      title: 'Characters',
      subtitle: count == 0
          ? 'Your cast'
          : (count == 1 ? '1 character' : '$count characters'),
      actions: <Widget>[
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      itemCount: characters.length,
      itemBuilder: (BuildContext context, int index) {
        final Character character = characters[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
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
/// name, role, and the details truncated to a short preview; a "See more"
/// control expands it inline to reveal the full details. On desktop/web a hover
/// highlight hints interactivity.
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

  /// The number of characters of the details shown collapsed before it is
  /// truncated with an ellipsis and a "See more" control.
  static const int _previewLength = 200;

  @override
  Widget build(BuildContext context) {
    final Character c = widget.character;
    final String details = c.notes.trim();
    final bool hasDetails = details.isNotEmpty;
    // Only offer "See more" when the details actually exceed the preview.
    final bool isTruncatable = details.length > _previewLength;
    final String preview = isTruncatable
        ? '${details.substring(0, _previewLength).trimRight()}…'
        : details;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        decoration: BoxDecoration(
          color: _hovered ? AppPalette.surfaceVariant : AppPalette.background,
          borderRadius: AppStyle.controlRadius,
          border: Border.all(
            color: _hovered ? AppPalette.primary : AppPalette.hairline,
          ),
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
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
            // The character details: shown truncated to [_previewLength]
            // characters with an ellipsis, and revealed in full when expanded.
            if (hasDetails) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _expanded ? details : preview,
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
            // "See more" / "See less" toggle, only when the details are longer
            // than the collapsed preview.
            if (isTruncatable)
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
        border: Border.all(color: AppPalette.hairline),
      ),
      child: c.image != null
          ? Image.memory(
              c.image!,
              fit: BoxFit.cover,
              semanticLabel: 'Portrait of ${c.displayName}',
            )
          : const Icon(Icons.person_outline,
              color: AppPalette.textSecondary, size: 24),
    );
  }
}
