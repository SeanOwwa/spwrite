// Unit tests for the Tier-1, fully-offline KeywordContextRetriever (task 2.4).
//
// Validates: Requirements 5.2, 5.5, 5.6, 5.7
//
// These tests drive KeywordContextRetriever against lightweight, in-memory fake
// repositories that mirror the project-scoping behavior the real SQLite
// repositories provide: getByProject / getAllForProject return only the rows
// whose projectId matches the requested project. The retriever is constructed
// with a single projectId, so a fake that honors project scoping is enough to
// prove that another project's material never surfaces (Req 5.6).
//
// The four behaviors under test (mirroring task 2.4):
//   1. Relevant passages surface for a query, ordered by descending score and
//      carrying their source titles (Req 5.2).
//   2. Content from other projects is excluded — the retriever only queries its
//      own projectId (Req 5.6).
//   3. Empty project: retrieve returns none AND hasProjectMaterial() is false;
//      a non-empty project with a no-match query returns none but
//      hasProjectMaterial() is true (Req 5.5).
//   4. refresh() rebuilds the index so edits/additions are reflected on
//      subsequent retrieve calls (Req 5.7).
//
// Only the two read methods the retriever actually calls are meaningfully
// implemented on the fakes; every other repository method throws
// UnimplementedError so an accidental dependency surfaces loudly.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:spwrite/data/ai/keyword_context_retriever.dart';
import 'package:spwrite/domain/ai/context_retriever.dart';
import 'package:spwrite/domain/character.dart';
import 'package:spwrite/domain/character_repository.dart';
import 'package:spwrite/domain/document.dart';
import 'package:spwrite/domain/document_repository.dart';

// ---------------------------------------------------------------------------
// Lightweight, project-scoped fake repositories.
//
// Both fakes hold a mutable in-memory list so a test can add/edit rows between
// a retrieve() and a refresh() to exercise index rebuilding (Req 5.7). Reads
// filter by projectId exactly as the real repositories do, which is what makes
// the "other projects excluded" test meaningful (Req 5.6).
// ---------------------------------------------------------------------------

class _FakeDocumentRepository implements DocumentRepository {
  _FakeDocumentRepository(this.documents);

  /// Mutable so tests can edit/add documents and then refresh() the index.
  final List<Document> documents;

  @override
  Future<List<Document>> getByProject(String projectId) async {
    return documents
        .where((Document d) => d.projectId == projectId)
        .toList(growable: false);
  }

  @override
  Future<List<Document>> getByContainer(String projectId, String? folderId) =>
      throw UnimplementedError();

  @override
  Future<Document?> getById(String id) => throw UnimplementedError();

  @override
  Future<Document> create(Document doc) => throw UnimplementedError();

  @override
  Future<void> update(Document doc) => throw UnimplementedError();

  @override
  Future<void> updatePositions(List<Document> documents) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

class _FakeCharacterRepository implements CharacterRepository {
  _FakeCharacterRepository(this.characters);

  /// Mutable so tests can add characters and then refresh() the index.
  final List<Character> characters;

  @override
  Future<List<Character>> getAllForProject(String projectId) async {
    return characters
        .where((Character c) => c.projectId == projectId)
        .toList(growable: false);
  }

  @override
  Future<Character?> getById(String id) => throw UnimplementedError();

  @override
  Future<Character> create(Character character) => throw UnimplementedError();

  @override
  Future<void> update(Character character) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Builders — keep each test focused on the query/ranking behavior, not on the
// boilerplate of a fully-populated domain entity.
// ---------------------------------------------------------------------------

final DateTime _ts = DateTime.utc(2024, 1, 1);

Document _doc({
  required String id,
  required String projectId,
  String title = '',
  String content = '',
}) {
  return Document(
    id: id,
    title: title,
    content: content,
    projectId: projectId,
    folderId: null,
    createdAt: _ts,
    modifiedAt: _ts,
  );
}

Character _character({
  required String id,
  required String projectId,
  String name = '',
  String role = '',
  String notes = '',
  Uint8List? image,
}) {
  return Character(
    id: id,
    projectId: projectId,
    name: name,
    role: role,
    notes: notes,
    image: image,
    createdAt: _ts,
    modifiedAt: _ts,
  );
}

KeywordContextRetriever _retriever({
  List<Document> documents = const <Document>[],
  List<Character> characters = const <Character>[],
  String projectId = 'project-1',
}) {
  return KeywordContextRetriever(
    documentRepository: _FakeDocumentRepository(documents),
    characterRepository: _FakeCharacterRepository(characters),
    projectId: projectId,
  );
}

void main() {
  group('retrieve: relevant passages surface (Req 5.2)', () {
    test('surfaces the passage whose content matches the query', () async {
      final retriever = _retriever(
        documents: <Document>[
          _doc(
            id: 'doc-dragon',
            projectId: 'project-1',
            title: 'Dragon lore',
            content: 'The ancient dragon guards a hoard of gold in the '
                'mountain caverns.',
          ),
          _doc(
            id: 'doc-harbor',
            projectId: 'project-1',
            title: 'Harbor town',
            content: 'Fishing boats drift into the quiet harbor at dawn.',
          ),
        ],
      );

      final List<RetrievedPassage> results =
          await retriever.retrieve('dragon hoard gold');

      expect(results, isNotEmpty);
      expect(results.first.sourceId, 'doc-dragon');
      expect(results.first.sourceTitle, 'Dragon lore');
      expect(results.first.text, contains('dragon'));
    });

    test('orders results by descending score and carries source titles',
        () async {
      // "wizard" appears in three passages, so its IDF is low; "grimoire" is
      // rare, so the passage carrying both terms should outrank a passage that
      // only shares the common term.
      final retriever = _retriever(
        documents: <Document>[
          _doc(
            id: 'doc-strong',
            projectId: 'project-1',
            title: 'The Grimoire',
            content:
                'The wizard studied the forbidden grimoire by candlelight.',
          ),
          _doc(
            id: 'doc-weak',
            projectId: 'project-1',
            title: 'Village Wizard',
            content: 'The village wizard sold charms in the market square.',
          ),
          _doc(
            id: 'doc-other',
            projectId: 'project-1',
            title: 'Wizard Council',
            content: 'The wizard council convened at the tower each spring.',
          ),
        ],
      );

      final List<RetrievedPassage> results =
          await retriever.retrieve('grimoire wizard');

      expect(results.length, greaterThanOrEqualTo(2));
      // Highest-relevance passage first (the one carrying the rare term).
      expect(results.first.sourceId, 'doc-strong');
      expect(results.first.sourceTitle, 'The Grimoire');

      // Scores are sorted descending across all returned passages.
      for (int i = 0; i + 1 < results.length; i++) {
        expect(
          results[i].score,
          greaterThanOrEqualTo(results[i + 1].score),
          reason: 'passages must be ordered by descending relevance',
        );
      }
    });

    test('surfaces a character passage by its notes and uses the character '
        'display name as the source title', () async {
      final retriever = _retriever(
        characters: <Character>[
          _character(
            id: 'char-mara',
            projectId: 'project-1',
            name: 'Mara',
            role: 'Protagonist',
            notes: 'A cartographer haunted by a shipwreck she survived.',
          ),
        ],
      );

      final List<RetrievedPassage> results =
          await retriever.retrieve('cartographer shipwreck');

      expect(results, isNotEmpty);
      expect(results.first.sourceId, 'char-mara');
      expect(results.first.sourceTitle, 'Mara');
    });
  });

  group('retrieve: other projects are excluded (Req 5.6)', () {
    test('only surfaces material from the scoped project', () async {
      // Both projects contain the exact same searchable term. The retriever is
      // scoped to project-1, so only project-1's document may appear.
      final retriever = _retriever(
        projectId: 'project-1',
        documents: <Document>[
          _doc(
            id: 'mine',
            projectId: 'project-1',
            title: 'My lighthouse',
            content: 'The lighthouse keeper logs the passing ships.',
          ),
          _doc(
            id: 'theirs',
            projectId: 'project-2',
            title: 'Their lighthouse',
            content: 'The lighthouse keeper logs the passing ships.',
          ),
        ],
        characters: <Character>[
          _character(
            id: 'their-char',
            projectId: 'project-2',
            name: 'Keeper',
            notes: 'Tends the lighthouse lamp every night.',
          ),
        ],
      );

      final List<RetrievedPassage> results =
          await retriever.retrieve('lighthouse keeper');

      expect(results, isNotEmpty);
      expect(
        results.map((RetrievedPassage p) => p.sourceId),
        everyElement('mine'),
        reason: 'no passage from another project may be surfaced',
      );
    });
  });

  group('empty vs no-match (Req 5.5)', () {
    test('empty project: retrieve returns none and hasProjectMaterial is false',
        () async {
      final retriever = _retriever();

      expect(await retriever.retrieve('anything at all'), isEmpty);
      expect(await retriever.hasProjectMaterial(), isFalse);
    });

    test('a project whose only content is empty/whitespace has no material',
        () async {
      // A document with no usable content and a character with only blank
      // fields contribute no passages, so the project is effectively empty.
      final retriever = _retriever(
        documents: <Document>[
          _doc(id: 'blank', projectId: 'project-1', title: '', content: '   '),
        ],
        characters: <Character>[
          _character(id: 'blank-char', projectId: 'project-1'),
        ],
      );

      expect(await retriever.hasProjectMaterial(), isFalse);
      expect(await retriever.retrieve('search'), isEmpty);
    });

    test('non-empty project with a no-match query: retrieve none but '
        'hasProjectMaterial is true', () async {
      final retriever = _retriever(
        documents: <Document>[
          _doc(
            id: 'doc-1',
            projectId: 'project-1',
            title: 'Orchard',
            content: 'Apple and pear trees ripen through the long summer.',
          ),
        ],
      );

      // A query whose usable terms overlap nothing in the index.
      expect(await retriever.retrieve('spaceship telemetry'), isEmpty);
      // ...yet the project clearly has material to search.
      expect(await retriever.hasProjectMaterial(), isTrue);
    });

    test('a query with only stopwords/short tokens returns none even with '
        'material present', () async {
      final retriever = _retriever(
        documents: <Document>[
          _doc(
            id: 'doc-1',
            projectId: 'project-1',
            title: 'Notes',
            content: 'The knight rode north through the frozen pass.',
          ),
        ],
      );

      expect(await retriever.retrieve('the and to a of'), isEmpty);
      expect(await retriever.hasProjectMaterial(), isTrue);
    });
  });

  group('refresh rebuilds the index (Req 5.7)', () {
    test('an edit to a document is reflected after refresh', () async {
      final List<Document> documents = <Document>[
        _doc(
          id: 'doc-1',
          projectId: 'project-1',
          title: 'Chapter one',
          content: 'The caravan crossed the desert under a blazing sun.',
        ),
      ];
      final retriever = _retriever(documents: documents);

      // Before the edit, the new term does not exist anywhere in the index.
      expect(await retriever.retrieve('volcano'), isEmpty);

      // Edit the underlying document (as the repository would after a save).
      documents[0] = documents[0].copyWith(
        content: 'The caravan skirted the smoking volcano at the mountain pass.',
      );

      // A stale index still cannot find it...
      expect(await retriever.retrieve('volcano'), isEmpty);

      // ...until the index is rebuilt on demand.
      await retriever.refresh();

      final List<RetrievedPassage> afterRefresh =
          await retriever.retrieve('volcano');
      expect(afterRefresh, isNotEmpty);
      expect(afterRefresh.first.sourceId, 'doc-1');
    });

    test('a newly added character is searchable after refresh', () async {
      final List<Character> characters = <Character>[];
      final retriever = _retriever(characters: characters);

      // A brand-new project has no material.
      expect(await retriever.hasProjectMaterial(), isFalse);
      expect(await retriever.retrieve('alchemist'), isEmpty);

      // Add a character, mirroring "a character is added" in Req 5.7.
      characters.add(
        _character(
          id: 'char-new',
          projectId: 'project-1',
          name: 'Sable',
          role: 'Alchemist',
          notes: 'Brews tinctures from moonlit herbs.',
        ),
      );

      // Not visible until the index is rebuilt.
      expect(await retriever.retrieve('alchemist'), isEmpty);

      await retriever.refresh();

      expect(await retriever.hasProjectMaterial(), isTrue);
      final List<RetrievedPassage> results =
          await retriever.retrieve('alchemist tinctures');
      expect(results, isNotEmpty);
      expect(results.first.sourceId, 'char-new');
      expect(results.first.sourceTitle, 'Sable');
    });
  });
}
