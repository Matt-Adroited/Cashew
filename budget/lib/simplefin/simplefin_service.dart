import 'package:budget/database/tables.dart';
import 'package:budget/simplefin/simplefin_client.dart';
import 'package:budget/simplefin/simplefin_storage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/drift.dart' show Value;

class SimplefinSyncResult {
  final int imported;
  final int skipped;
  final List<String> errors;

  const SimplefinSyncResult({
    required this.imported,
    required this.skipped,
    required this.errors,
  });
}

class SimplefinService {
  /// Exchange a setup token for an access URL and persist it.
  static Future<String> exchangeAndSaveToken(String setupToken) async {
    final accessUrl = await SimplefinClient.exchangeSetupToken(setupToken);
    await SimplefinStorage.saveAccessUrl(accessUrl);
    return accessUrl;
  }

  /// Fetch accounts from SimpleFIN (used to populate account mapping UI).
  static Future<List<SimplefinAccount>> fetchAccountsForMapping() async {
    final accessUrl = await SimplefinStorage.getAccessUrl();
    if (accessUrl == null) throw 'No SimpleFIN access URL configured';
    return SimplefinClient.fetchAccounts(accessUrl);
  }

  /// Run a full sync: fetch transactions and upsert them into Drift.
  ///
  /// Uses a 3-day overlap before the last sync to catch late-posting
  /// transactions without missing anything.
  static Future<SimplefinSyncResult> sync({bool fullSync = false}) async {
    final accessUrl = await SimplefinStorage.getAccessUrl();
    if (accessUrl == null) throw 'No SimpleFIN access URL configured';

    final mappings = SimplefinStorage.getAccountMappings();

    // Ensure an Uncategorized category exists for SimpleFIN imports
    const uncategorizedPk = 'sf-uncategorized';
    final allCategories = await database.getAllCategories();
    await database.createOrUpdateCategory(
      TransactionCategory(
        categoryPk: uncategorizedPk,
        name: 'Uncategorized',
        colour: null,
        iconName: null,
        emojiIconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: Value(DateTime.now()).value,
        order: allCategories.length,
        income: false,
        methodAdded: MethodAdded.simplefin,
        mainCategoryPk: null,
      ),
      updateSharedEntry: false,
    );
    final defaultCategoryPk =
        SimplefinStorage.getDefaultCategoryPk() ?? uncategorizedPk;

    final lastSync = fullSync ? null : SimplefinStorage.getLastSyncTime();
    // First sync or full sync: go back 90 days. Subsequent syncs: overlap 3 days to catch late-posting transactions.
    final startDate = lastSync != null
        ? lastSync.subtract(const Duration(days: 3))
        : DateTime.now().subtract(const Duration(days: 44));

    final accounts = await SimplefinClient.fetchAccounts(
      accessUrl,
      startDate: startDate,
    );

    int imported = 0;
    int skipped = 0;
    final errors = <String>[];

    // Mutable copy so we can persist new auto-created mappings
    final updatedMappings = Map<String, String>.from(mappings);

    for (final account in accounts) {
      String? walletPk = updatedMappings[account.id];

      // null (unmapped) or 'skip' both mean skip
      if (walletPk == null || walletPk == 'skip') {
        skipped += account.transactions.length;
        continue;
      }

      // 'auto' means create a new Cashew wallet for this account
      if (walletPk == 'auto') {
        try {
          final existingWallets = await database.getAllWallets();
          final newPk = uuid.v4();
          await database.createOrUpdateWallet(
            TransactionWallet(
              walletPk: newPk,
              name: account.name.isNotEmpty ? account.name : account.orgName,
              colour: null,
              iconName: null,
              dateCreated: DateTime.now(),
              dateTimeModified: Value(DateTime.now()).value,
              order: existingWallets.length,
              currency: account.currency.isNotEmpty ? account.currency : null,
              currencyFormat: null,
              decimals: 2,
              homePageWidgetDisplay: null,
            ),
          );
          updatedMappings[account.id] = newPk;
          await SimplefinStorage.saveAccountMappings(updatedMappings);
          walletPk = newPk;
        } catch (e) {
          errors.add('Failed to create wallet for ${account.name}: $e');
          skipped += account.transactions.length;
          continue;
        }
      }

      for (final txn in account.transactions) {
        try {
          final rawAmount = txn.amountDouble;
          final isIncome = rawAmount >= 0;
          final amount = rawAmount; // Cashew stores negative amounts for expenses

          // Use 'sf-{id}' as transactionPk for natural deduplication.
          // createOrUpdateTransaction uses insertOrReplace, so re-syncing
          // the same transaction ID is safe.
          await database.createOrUpdateTransaction(
            Transaction(
              transactionPk: 'sf-${txn.id}',
              name: txn.description,
              amount: amount,
              note: '',
              categoryFk: defaultCategoryPk,
              walletFk: walletPk,
              dateCreated: txn.date,
              dateTimeModified: DateTime.now(),
              income: isIncome,
              paid: true,
              skipPaid: false,
              methodAdded: MethodAdded.simplefin,
            ),
            updateSharedEntry: false,
          );
          imported++;
        } catch (e) {
          errors.add('txn ${txn.id}: $e');
        }
      }

      // Create/update an opening balance correction so the wallet balance
      // matches SimpleFIN's reported balance, accounting for history
      // outside our 45-day window.
      try {
        final reportedBalance = account.balanceDouble;
        final allWalletTxns = await (database.select(database.transactions)
              ..where((t) => t.walletFk.equals(walletPk!)))
            .get();
        final sfTxns = allWalletTxns.where((t) =>
            t.methodAdded == MethodAdded.simplefin &&
            t.transactionPk != 'sf-balance-${account.id}');
        // Amounts are signed in Cashew (negative for expenses) — just sum directly
        final importedSum = sfTxns.fold<double>(
            0.0, (sum, t) => sum + t.amount);
        final correction = reportedBalance - importedSum;

        if (correction.abs() > 0.01) {
          await database.createOrUpdateTransaction(
            Transaction(
              transactionPk: 'sf-balance-${account.id}',
              name: 'Opening Balance',
              amount: correction, // signed: negative = expense, positive = income
              note: 'Auto-generated to match SimpleFIN reported balance',
              categoryFk: defaultCategoryPk,
              walletFk: walletPk!,
              dateCreated: account.balanceDate != 0
                  ? account.balanceDatetime
                  : startDate,
              dateTimeModified: DateTime.now(),
              income: correction >= 0,
              paid: true,
              skipPaid: false,
              methodAdded: MethodAdded.simplefin,
            ),
            updateSharedEntry: false,
          );
        }
      } catch (e) {
        errors.add('balance correction for ${account.name}: $e');
      }
    }

    await SimplefinStorage.saveLastSyncTime(DateTime.now());
    return SimplefinSyncResult(
        imported: imported, skipped: skipped, errors: errors);
  }

  /// Delete all SimpleFIN-imported transactions and reset the last sync time.
  /// Wallets are kept so the user doesn't lose their account setup.
  static Future<int> clearSyncData() async {
    final sfTransactions = await (database.select(database.transactions)
          ..where((t) =>
              t.methodAdded.equalsValue(MethodAdded.simplefin)))
        .get();
    final pks = sfTransactions.map((t) => t.transactionPk).toList();
    if (pks.isNotEmpty) {
      await database.deleteTransactions(pks, updateSharedEntry: false);
    }
    await SimplefinStorage.clearLastSyncTime();
    return pks.length;
  }

  /// Returns true if a sync should be triggered (access URL set and
  /// last sync was more than [intervalHours] ago or never synced).
  static Future<bool> shouldAutoSync({int intervalHours = 1}) async {
    final accessUrl = await SimplefinStorage.getAccessUrl();
    if (accessUrl == null) return false;
    final lastSync = SimplefinStorage.getLastSyncTime();
    if (lastSync == null) return true;
    return DateTime.now().difference(lastSync).inHours >= intervalHours;
  }
}
