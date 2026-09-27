/// Presentation layer: [CharacterEditView], the full-screen form for creating
/// or editing a single [Character].
///
/// It is pushed as its own route from the character sidebar (a new page/screen,
/// as required) so the author has room to write. It edits a local working copy
/// of the character's fields and portrait image, and on save forwards the copy
/// to [CharacterPanelState.saveCharacter]; on delete it forwards to
/// [CharacterPanelState.deleteCharacter]. All colors are drawn from
/// [AppPalette] so the screen matches the dark navy theme.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/character.dart';
import '../state/character_panel_state.dart';
import '../theme/app_theme.dart';
import 'delete_confirmation_dialog.dart';

/// A full-screen create/edit form for one [Character]. Pushed as a route by the
/// character sidebar; pops itself after a successful save or delete.
class CharacterEditView extends StatefulWidget {
  /// The character being edited. For a freshly created character this is the
  /// blank entity returned by [CharacterPanelState.createCharacter].
  final Character character;

  /// The panel state to persist changes through. Passed explicitly because the
  /// route is pushed with the app's root navigator and does not necessarily
  /// inherit the workspace provider scope.
  final CharacterPanelState panelState;

  const CharacterEditView({
    super.key,
    required this.character,
    required this.panelState,
  });

  @override
  State<CharacterEditView> createState() => _CharacterEditViewState();
}

class _CharacterEditViewState extends State<CharacterEditView> {
  late final TextEditingController _nameController;
  late final TextEditingController _roleController;
  late final TextEditingController _notesController;

  /// The working copy of the portrait image bytes, or `null` when none is set.
  Uint8List? _imageBytes;

  /// Whether a save is in flight (disables the save control to avoid
  /// double-submits).
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.character.name);
    _roleController = TextEditingController(text: widget.character.role);
    _notesController = TextEditingController(text: widget.character.notes);
    _imageBytes = widget.character.image;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _roleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Opens the platform image picker and stores the chosen image's bytes in the
  /// working copy. The picker is capped to a reasonable size so portraits do
  /// not bloat the database.
  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (file == null) return;
      final Uint8List bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => _imageBytes = bytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load that image.')),
      );
    }
  }

  /// Clears the working-copy image.
  void _removeImage() {
    setState(() => _imageBytes = null);
  }

  /// Builds the edited character from the current field values and persists it,
  /// then pops the route.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    final Character edited = widget.character.copyWith(
      name: _nameController.text.trim(),
      role: _roleController.text.trim(),
      notes: _notesController.text,
      image: _imageBytes,
      clearImage: _imageBytes == null,
    );

    await widget.panelState.saveCharacter(edited);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Confirms and deletes the character, then pops the route.
  Future<void> _delete() async {
    final bool confirmed = await DeleteConfirmationDialog.showForCharacter(
      context,
      characterName: widget.character.displayName,
    );
    if (!confirmed) return;
    await widget.panelState.deleteCharacter(widget.character.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: const Text('Character'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Delete character',
            icon: const Icon(Icons.delete_outline, color: AppPalette.error),
            onPressed: _saving ? null : _delete,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: <Widget>[
                _buildImagePicker(context),
                const SizedBox(height: 24),
                _buildField(
                  label: 'Name',
                  controller: _nameController,
                  hint: 'e.g. Eleanor Vance',
                  maxLength: Character.maxNameLength,
                ),
                const SizedBox(height: 16),
                _buildField(
                  label: 'Role',
                  controller: _roleController,
                  hint: 'e.g. Protagonist, Mentor, Antagonist',
                  maxLength: Character.maxRoleLength,
                ),
                const SizedBox(height: 16),
                _buildField(
                  label: 'Details',
                  controller: _notesController,
                  hint: 'Backstory, appearance, relationships, arc…',
                  maxLength: Character.maxNotesLength,
                  maxLines: 12,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The portrait image picker: a circular avatar preview with controls to
  /// choose or remove the image.
  Widget _buildImagePicker(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          width: 128,
          height: 128,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppPalette.surfaceVariant,
            shape: BoxShape.circle,
            border: Border.all(color: AppPalette.outline),
          ),
          child: _imageBytes != null
              ? Image.memory(_imageBytes!, fit: BoxFit.cover)
              : const Icon(
                  Icons.person_outline,
                  size: 56,
                  color: AppPalette.textSecondary,
                ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            TextButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image_outlined),
              label: Text(_imageBytes == null ? 'Add image' : 'Change image'),
            ),
            if (_imageBytes != null) ...<Widget>[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _removeImage,
                icon: const Icon(Icons.close),
                label: const Text('Remove'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// A labelled text field drawn from the dark palette.
  Widget _buildField({
    required String label,
    required TextEditingController controller,
    required String hint,
    required int maxLength,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          maxLength: maxLength,
          style: const TextStyle(color: AppPalette.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            counterText: '',
          ),
        ),
      ],
    );
  }
}
