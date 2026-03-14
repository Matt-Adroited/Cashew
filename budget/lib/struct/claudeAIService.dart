import 'dart:convert';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/claudeAIStorage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;

class ClaudeAIService {
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _model = 'claude-haiku-4-5-20251001';
  static const _anthropicVersion = '2023-06-01';
  static const _batchSize = 50;

  static const List<String> defaultCategoryNames = [
    'Groceries',
    'Restaurants & Dining',
    'Fast Food',
    'Coffee & Cafes',
    'Gas & Fuel',
    'Auto & Transport',
    'Parking',
    'Public Transit',
    'Rent & Mortgage',
    'Utilities',
    'Internet & Phone',
    'Subscriptions',
    'Streaming Services',
    'Shopping',
    'Clothing & Apparel',
    'Electronics',
    'Health & Medical',
    'Pharmacy',
    'Gym & Fitness',
    'Entertainment',
    'Travel & Hotels',
    'Flights',
    'Personal Care',
    'Home & Garden',
    'Pet Care',
    'Education',
    'Gifts & Donations',
    'Income',
    'Paycheck',
    'Credit Card Payment',
    'Transfer',
  ];

  static const Set<String> _incomeCategories = {'Income', 'Paycheck'};

  /// Seed the default category list into the database, skipping any that
  /// already exist (matched by name, case-insensitive).
  /// Returns the number of new categories created.
  static Future<int> seedDefaultCategories() async {
    final existing = await database.getAllCategories();
    final existingNames = existing.map((c) => c.name.toLowerCase()).toSet();
    int added = 0;
    for (final name in defaultCategoryNames) {
      if (!existingNames.contains(name.toLowerCase())) {
        final slug =
            name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
        await database.createOrUpdateCategory(
          TransactionCategory(
            categoryPk: 'ai-cat-$slug',
            name: name,
            colour: null,
            iconName: null,
            emojiIconName: null,
            dateCreated: DateTime.now(),
            dateTimeModified: Value(DateTime.now()).value,
            order: existing.length + added,
            income: _incomeCategories.contains(name),
            methodAdded: MethodAdded.simplefin,
            mainCategoryPk: null,
          ),
          updateSharedEntry: false,
        );
        added++;
      }
    }
    return added;
  }

  /// Categorize all transactions currently in the "Uncategorized" category
  /// using Claude Haiku. Updates each transaction's categoryFk in-place.
  /// Returns the total number of transactions successfully re-categorized.
  static Future<int> categorizeUncategorizedTransactions({
    Function(int done, int total)? onProgress,
  }) async {
    const uncategorizedPk = 'sf-uncategorized';

    final uncategorized =
        await database.getAllTransactionsFromCategory(uncategorizedPk);
    if (uncategorized.isEmpty) return 0;

    final allCategories = await database.getAllCategories();
    final categories = allCategories
        .where((c) => c.categoryPk != uncategorizedPk)
        .toList();
    if (categories.isEmpty) return 0;

    int done = 0;
    final total = uncategorized.length;

    for (int i = 0; i < total; i += _batchSize) {
      final batch = uncategorized.skip(i).take(_batchSize).toList();
      final results = await _categorizeBatch(batch, categories);

      for (final entry in results.entries) {
        final txn =
            batch.firstWhere((t) => t.transactionPk == entry.key);
        await database.createOrUpdateTransaction(
          txn.copyWith(categoryFk: entry.value),
          updateSharedEntry: false,
          insert: false,
        );
        done++;
      }
      onProgress?.call(done, total);
    }
    return done;
  }

  /// Send a batch of transactions to Claude Haiku and return a map of
  /// transactionPk -> categoryPk.
  static Future<Map<String, String>> _categorizeBatch(
    List<Transaction> transactions,
    List<TransactionCategory> categories,
  ) async {
    final apiKey = await ClaudeAIStorage.getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw 'No Claude API key configured';
    }

    final categoryNames = categories.map((c) => c.name).join(', ');
    final transactionLines = transactions
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value.name}')
        .join('\n');

    final prompt =
        'Categorize each transaction below. For each, choose the single best '
        'category from the provided list. Reply with a JSON array of category '
        'names in the same order as the transactions. Only use names exactly as '
        'they appear in the category list. If none fit well, use "Uncategorized".\n\n'
        'Important rules:\n'
        '- Transactions with words like "payment", "autopay", "online payment", '
        '"thank you", or "pymt" that appear to be bill or credit card payments '
        'should be categorized as "Credit Card Payment" if that category exists, '
        'otherwise "Transfer".\n'
        '- Only use "Income" or "Paycheck" for actual earnings like wages, salary, '
        'direct deposit from an employer, or investment returns.\n\n'
        'Categories: $categoryNames'
        '\n\nTransactions:\n$transactionLines'
        '\n\nReply with only the JSON array, no other text.';

    final response = await http.post(
      Uri.parse(_apiUrl),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': _anthropicVersion,
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'max_tokens': 1024,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final message =
          (body['error'] as Map<String, dynamic>?)?['message'] ??
              'HTTP ${response.statusCode}';
      throw 'Claude API error: $message';
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content =
        ((data['content'] as List).first as Map<String, dynamic>)['text']
            as String;

    final List<dynamic> results = jsonDecode(content.trim());
    final categoryByName = {
      for (final c in categories) c.name: c.categoryPk
    };

    final result = <String, String>{};
    for (int i = 0; i < transactions.length && i < results.length; i++) {
      final categoryName = results[i] as String;
      final categoryPk = categoryByName[categoryName];
      if (categoryPk != null) {
        result[transactions[i].transactionPk] = categoryPk;
      }
    }
    return result;
  }
}
