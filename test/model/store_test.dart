import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/core.dart';
import 'package:zulip/api/exception.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/events.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/api/route/realm.dart';
import 'package:zulip/log.dart';
import 'package:zulip/model/actions.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/notifications/receive.dart';

import '../api/fake_api.dart';
import '../api/model/model_checks.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import '../stdlib_checks.dart';
import 'binding.dart';
import 'store_checks.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  final account1 = eg.selfAccount.copyWith(id: 1);
  final account2 = eg.otherAccount.copyWith(id: 2);

  test('GlobalStore.perAccount sequential case', () async {
    final accounts = [account1, account2];
    final globalStore = LoadingTestGlobalStore(accounts: accounts);
    List<Completer<PerAccountStore>> completers(int accountId) =>
      globalStore.completers[accountId]!;

    final future1 = globalStore.perAccount(1);
    final store1 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 1,
      initialSnapshot: eg.initialSnapshot(),
    );
    completers(1).single.complete(store1);
    check(await future1).identicalTo(store1);
    check(await globalStore.perAccount(1)).identicalTo(store1);
    check(completers(1)).length.equals(1);

    final future2 = globalStore.perAccount(2);
    final store2 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 2,
      initialSnapshot: eg.initialSnapshot(),
    );
    completers(2).single.complete(store2);
    check(await future2).identicalTo(store2);
    check(await globalStore.perAccount(2)).identicalTo(store2);
    check(await globalStore.perAccount(1)).identicalTo(store1);

    // Only one loadPerAccount call was made per account.
    check(completers(1)).length.equals(1);
    check(completers(2)).length.equals(1);
  });

  test('GlobalStore.perAccount concurrent case', () async {
    final accounts = [account1, account2];
    final globalStore = LoadingTestGlobalStore(accounts: accounts);
    List<Completer<PerAccountStore>> completers(int accountId) =>
      globalStore.completers[accountId]!;

    final future1a = globalStore.perAccount(1);
    final future1b = globalStore.perAccount(1);
    // These should produce just one loadPerAccount call.
    check(completers(1)).length.equals(1);

    final future2 = globalStore.perAccount(2);
    final store1 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 1,
      initialSnapshot: eg.initialSnapshot(),
    );
    final store2 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 2,
      initialSnapshot: eg.initialSnapshot(),
    );
    completers(1).single.complete(store1);
    completers(2).single.complete(store2);
    check(await future1a).identicalTo(store1);
    check(await future1b).identicalTo(store1);
    check(await future2).identicalTo(store2);
    check(await globalStore.perAccount(1)).identicalTo(store1);
    check(await globalStore.perAccount(2)).identicalTo(store2);
    check(completers(1)).length.equals(1);
    check(completers(2)).length.equals(1);
  });

  test('GlobalStore.perAccountSync', () async {
    final accounts = [account1, account2];
    final globalStore = LoadingTestGlobalStore(accounts: accounts);
    List<Completer<PerAccountStore>> completers(int accountId) =>
      globalStore.completers[accountId]!;

    check(globalStore.perAccountSync(1)).isNull();
    final future1 = globalStore.perAccount(1);
    check(globalStore.perAccountSync(1)).isNull();
    final store1 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 1,
      initialSnapshot: eg.initialSnapshot(),
    );
    completers(1).single.complete(store1);
    await pumpEventQueue();
    check(globalStore.perAccountSync(1)).identicalTo(store1);
    check(await future1).identicalTo(store1);
    check(globalStore.perAccountSync(1)).identicalTo(store1);
    check(await globalStore.perAccount(1)).identicalTo(store1);
    check(completers(1)).length.equals(1);
  });

  test('GlobalStore.perAccount loading fails with HTTP status code 401', () => awaitFakeAsync((async) async {
    final globalStore = LoadingTestGlobalStore(accounts: [eg.selfAccount]);
    final future = globalStore.perAccount(eg.selfAccount.id);

    globalStore.completers[eg.selfAccount.id]!
      .single.completeError(eg.apiExceptionUnauthorized());
    await check(future).throws<AccountNotFoundException>();
  }));

  test('GlobalStore.perAccount loading succeeds', () => awaitFakeAsync((async) async {
    NotificationService.instance.token = ValueNotifier('asdf');
    addTearDown(NotificationService.debugReset);

    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await future;
    // poll, server-emoji-data, register-token requests
    check(connection.takeRequests()).length.equals(3);
    check(connection).isOpen.isTrue();
  }));

  test('GlobalStore.perAccount loading succeeds; InitialSnapshot has ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);
    // no poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount loading fails; malformed response with ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    json['realm_emoji'] = 123;
    check(() => InitialSnapshot.fromJson(json)).throws<void>();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);
    // no poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then succeeds', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) =>
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        json: eg.initialSnapshot().toJson());
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls())
      .single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then fails with HTTP status code 401', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) =>
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        apiException: eg.apiExceptionUnauthorized());
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls())
      .single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then succeeds; InitialSnapshot has ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then fails; malformed response with ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    json['realm_emoji'] = 123;
    check(() => InitialSnapshot.fromJson(json)).throws<void>();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    check(connection.takeRequests()).length.equals(1); // register request

    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out during transient-error backoff', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) =>
      connection.prepare(
        delay: Duration(seconds: 1),
        httpException: http.ClientException('Oops'));
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    BackoffMachine.debugDuration = Duration(seconds: 1);
    async.elapse(Duration(milliseconds: 1500));
    check(connection.takeRequests()).length.equals(1); // register request

    assert(TestGlobalStore.removeAccountDuration < Duration(milliseconds: 500));
    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls())
      .single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no retry-register, poll, server-emoji-data, or register-token requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount throws if missing queueId', () async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(json:
        deepToJson(eg.initialSnapshot()) as Map<String, dynamic>
          ..['queue_id'] = null);
    };
    await check(globalStore.perAccount(eg.selfAccount.id)).throws();
  });

  // TODO test insertAccount

  group('GlobalStore.updateAccount', () {
    test('basic', () async {
      // Update a nullable field, and a non-nullable one.
      final account = eg.selfAccount.copyWith(
        zulipFeatureLevel: 123,
        ackedPushToken: const Value('asdf'),
      );
      final globalStore = eg.globalStore(accounts: [account]);
      final updated = await globalStore.updateAccount(account.id,
        const AccountsCompanion(
          zulipFeatureLevel: Value(234),
          ackedPushToken: Value(null),
        ));
      check(globalStore.getAccount(account.id)).identicalTo(updated);
      check(updated).equals(account.copyWith(
        zulipFeatureLevel: 234,
        ackedPushToken: const Value(null),
      ));
    });

    test('notifyListeners called', () async {
      final globalStore = eg.globalStore(accounts: [eg.selfAccount]);
      int updateCount = 0;
      globalStore.addListener(() => updateCount++);
      check(updateCount).equals(0);

      await globalStore.updateAccount(eg.selfAccount.id, const AccountsCompanion(
        zulipFeatureLevel: Value(234),
      ));
      check(updateCount).equals(1);
    });

    test('reject changing id, realmUrl, or userId', () async {
      final globalStore = eg.globalStore(accounts: [eg.selfAccount]);
      await check(globalStore.updateAccount(eg.selfAccount.id, const AccountsCompanion(
        id: Value(1234)))).throws();
      await check(globalStore.updateAccount(eg.selfAccount.id, AccountsCompanion(
        realmUrl: Value(Uri.parse('https://other.example'))))).throws();
      await check(globalStore.updateAccount(eg.selfAccount.id, const AccountsCompanion(
        userId: Value(1234)))).throws();
    });

    // TODO test database gets updated correctly (an integration test with sqlite?)
  });
  
  test('GlobalStore.updateZulipVersionData', () async {
    final [currentZulipVersion,          newZulipVersion             ]
        = ['10.0-beta2-302-gf5b08b11f4', '10.0-beta2-351-g75ac8fe961'];
    final [currentZulipMergeBase,        newZulipMergeBase           ]
        = ['10.0-beta2-291-g33ffd8c040', '10.0-beta2-349-g463dc632b3'];
    final [currentZulipFeatureLevel,     newZulipFeatureLevel        ]
        = [368,                          370                         ];

    final selfAccount = eg.selfAccount.copyWith(
      zulipVersion: currentZulipVersion,
      zulipMergeBase: Value(currentZulipMergeBase),
      zulipFeatureLevel: currentZulipFeatureLevel);
    final globalStore = eg.globalStore(accounts: [selfAccount]);
    final updated = await globalStore.updateZulipVersionData(selfAccount.id,
      ZulipVersionData(
        zulipVersion: newZulipVersion,
        zulipMergeBase: newZulipMergeBase,
        zulipFeatureLevel: newZulipFeatureLevel));
    check(globalStore.getAccount(selfAccount.id)).identicalTo(updated);
    check(updated).equals(selfAccount.copyWith(
      zulipVersion: newZulipVersion,
      zulipMergeBase: Value(newZulipMergeBase),
      zulipFeatureLevel: newZulipFeatureLevel));
  });

  group('GlobalStore.removeAccount', () {
    void checkGlobalStore(GlobalStore store, int accountId, {
      required bool expectAccount,
      required bool expectStore,
    }) {
      expectAccount
        ? check(store.getAccount(accountId)).isNotNull()
        : check(store.getAccount(accountId)).isNull();
      expectStore
        ? check(store.perAccountSync(accountId)).isNotNull()
        : check(store.perAccountSync(accountId)).isNull();
    }

    test('when store loaded', () async {
      final globalStore = eg.globalStore();
      await globalStore.add(eg.selfAccount, eg.initialSnapshot());
      await globalStore.perAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: true);
      int notifyCount = 0;
      globalStore.addListener(() => notifyCount++);

      await globalStore.removeAccount(eg.selfAccount.id);

      // TODO test that the removed store got disposed and its connection closed
      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1);
    });

    test('when store not loaded', () async {
      final globalStore = eg.globalStore();
      await globalStore.add(eg.selfAccount, eg.initialSnapshot());

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: false);
      int notifyCount = 0;
      globalStore.addListener(() => notifyCount++);

      await globalStore.removeAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1);
    });

    test('when store loading', () async {
      final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: false);

      assert(globalStore.useCachedApiConnections);
      // Cache a connection and get this reference to it,
      // so we can check later that it gets closed.
      final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;

      globalStore.prepareRegisterQueueResponse = (connection) {
        connection.prepare(
          delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
          json: eg.initialSnapshot().toJson());
      };
      final loadingFuture = globalStore.perAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: false);
      int notifyCount = 0;
      globalStore.addListener(() => notifyCount++);

      await globalStore.removeAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1);

      await check(loadingFuture).throws<AccountNotFoundException>();
      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1); // no extra notify
      check(connection).isOpen.isFalse();

      check(globalStore.debugNumPerAccountStoresLoading).equals(0);
    });
  });

  group('PerAccountStore.hasPassedWaitingPeriod', () {
    final store = eg.store(initialSnapshot:
      eg.initialSnapshot(realmWaitingPeriodThreshold: 2));

    final testCases = [
      ('2024-11-25T10:00+00:00', DateTime.utc(2024, 11, 25 + 0, 10, 00), false),
      ('2024-11-25T10:00+00:00', DateTime.utc(2024, 11, 25 + 1, 10, 00), false),
      ('2024-11-25T10:00+00:00', DateTime.utc(2024, 11, 25 + 2, 09, 59), false),
      ('2024-11-25T10:00+00:00', DateTime.utc(2024, 11, 25 + 2, 10, 00), true),
      ('2024-11-25T10:00+00:00', DateTime.utc(2024, 11, 25 + 1000, 07, 00), true),
    ];

    for (final (String dateJoined, DateTime currentDate, bool hasPassedWaitingPeriod) in testCases) {
      test('user joined at $dateJoined ${hasPassedWaitingPeriod ? 'has' : "hasn't"} '
          'passed waiting period by $currentDate', () {
        final user = eg.user(dateJoined: dateJoined);
        check(store.hasPassedWaitingPeriod(user, byDate: currentDate))
          .equals(hasPassedWaitingPeriod);
      });
    }
  });

  group('PerAccountStore.hasPostingPermission', () {
    final testCases = [
      (ChannelPostPolicy.unknown,        UserRole.unknown,       true),
      (ChannelPostPolicy.unknown,        UserRole.guest,         true),
      (ChannelPostPolicy.unknown,        UserRole.member,        true),
      (ChannelPostPolicy.unknown,        UserRole.moderator,     true),
      (ChannelPostPolicy.unknown,        UserRole.administrator, true),
      (ChannelPostPolicy.unknown,        UserRole.owner,         true),
      (ChannelPostPolicy.any,            UserRole.unknown,       true),
      (ChannelPostPolicy.any,            UserRole.guest,         true),
      (ChannelPostPolicy.any,            UserRole.member,        true),
      (ChannelPostPolicy.any,            UserRole.moderator,     true),
      (ChannelPostPolicy.any,            UserRole.administrator, true),
      (ChannelPostPolicy.any,            UserRole.owner,         true),
      (ChannelPostPolicy.fullMembers,    UserRole.unknown,       true),
      (ChannelPostPolicy.fullMembers,    UserRole.guest,         false),
      // The fullMembers/member case gets its own tests further below.
      // (ChannelPostPolicy.fullMembers,    UserRole.member,        /* complicated */),
      (ChannelPostPolicy.fullMembers,    UserRole.moderator,     true),
      (ChannelPostPolicy.fullMembers,    UserRole.administrator, true),
      (ChannelPostPolicy.fullMembers,    UserRole.owner,         true),
      (ChannelPostPolicy.moderators,     UserRole.unknown,       true),
      (ChannelPostPolicy.moderators,     UserRole.guest,         false),
      (ChannelPostPolicy.moderators,     UserRole.member,        false),
      (ChannelPostPolicy.moderators,     UserRole.moderator,     true),
      (ChannelPostPolicy.moderators,     UserRole.administrator, true),
      (ChannelPostPolicy.moderators,     UserRole.owner,         true),
      (ChannelPostPolicy.administrators, UserRole.unknown,       true),
      (ChannelPostPolicy.administrators, UserRole.guest,         false),
      (ChannelPostPolicy.administrators, UserRole.member,        false),
      (ChannelPostPolicy.administrators, UserRole.moderator,     false),
      (ChannelPostPolicy.administrators, UserRole.administrator, true),
      (ChannelPostPolicy.administrators, UserRole.owner,         true),
    ];

    for (final (ChannelPostPolicy policy, UserRole role, bool canPost) in testCases) {
      test('"${role.name}" user ${canPost ? 'can' : "can't"} post in channel '
          'with "${policy.name}" policy', () {
        final store = eg.store();
        final actual = store.hasPostingPermission(
          inChannel: eg.stream(channelPostPolicy: policy), user: eg.user(role: role),
          // [byDate] is not actually relevant for these test cases; for the
          // ones which it is, they're practiced below.
          byDate: DateTime.now());
        check(actual).equals(canPost);
      });
    }

    group('"member" user posting in a channel with "fullMembers" policy', () {
      PerAccountStore localStore({required int realmWaitingPeriodThreshold}) =>
        eg.store(initialSnapshot: eg.initialSnapshot(
          realmWaitingPeriodThreshold: realmWaitingPeriodThreshold));

      User memberUser({required String dateJoined}) => eg.user(
        role: UserRole.member, dateJoined: dateJoined);

      test('a "full" member -> can post in the channel', () {
        final store = localStore(realmWaitingPeriodThreshold: 3);
        final hasPermission = store.hasPostingPermission(
          inChannel: eg.stream(channelPostPolicy: ChannelPostPolicy.fullMembers),
          user: memberUser(dateJoined: '2024-11-25T10:00+00:00'),
          byDate: DateTime.utc(2024, 11, 28, 10, 00));
        check(hasPermission).isTrue();
      });

      test('not a "full" member -> cannot post in the channel', () {
        final store = localStore(realmWaitingPeriodThreshold: 3);
        final actual = store.hasPostingPermission(
          inChannel: eg.stream(channelPostPolicy: ChannelPostPolicy.fullMembers),
          user: memberUser(dateJoined: '2024-11-25T10:00+00:00'),
          byDate: DateTime.utc(2024, 11, 28, 09, 59));
        check(actual).isFalse();
      });
    });
  });

  group('PerAccountStore.handleEvent', () {
    // Mostly this method just dispatches to ChannelStore and MessageStore etc.,
    // and so its tests generally live in the test files for those
    // (but they call the handleEvent method because it's the entry point).
  });

  group('PerAccountStore.sendMessage', () {
    test('smoke', () async {
      final store = eg.store(initialSnapshot: eg.initialSnapshot(
        queueId: 'fb67bf8a-c031-47cc-84cf-ed80accacda8'));
      final connection = store.connection as FakeApiConnection;
      final stream = eg.stream();
      connection.prepare(json: SendMessageResult(id: 12345).toJson());
      await store.sendMessage(
        destination: StreamDestination(stream.streamId, eg.t('world')),
        content: 'hello');
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/messages')
        ..bodyFields.deepEquals({
          'type': 'stream',
          'to': stream.streamId.toString(),
          'topic': 'world',
          'content': 'hello',
          'read_by_sender': 'true',
          'queue_id': 'fb67bf8a-c031-47cc-84cf-ed80accacda8',
          'local_id': store.outboxMessages.keys.single.toString(),
        });
    });
  });

  group('UpdateMachine.load', () {
    late TestGlobalStore globalStore;
    late FakeApiConnection connection;

    Future<void> prepareStore({Account? account}) async {
      globalStore = eg.globalStore();
      account ??= eg.selfAccount;
      await globalStore.insertAccount(account.toCompanion(false));
      connection = (globalStore.apiConnectionFromAccount(account)
        as FakeApiConnection);
      UpdateMachine.debugEnableFetchEmojiData = false;
      addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
      UpdateMachine.debugEnableRegisterNotificationToken = false;
      addTearDown(() => UpdateMachine.debugEnableRegisterNotificationToken = true);
    }

    void checkLastRequest() {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/register');
    }

    test('smoke', () => awaitFakeAsync((async) async {
      await prepareStore();
      final users = [eg.selfUser, eg.otherUser];

      globalStore.useCachedApiConnections = true;
      connection.prepare(json: eg.initialSnapshot(realmUsers: users).toJson());
      final updateMachine = await UpdateMachine.load(
        globalStore, eg.selfAccount.id);
      updateMachine.debugPauseLoop();

      // TODO UpdateMachine.debugPauseLoop is too late to prevent first poll attempt;
      //    the polling retry catches the resulting NetworkException from lack of
      //    `connection.prepare`, so that doesn't fail the test, but it does
      //    clobber the recorded registerQueue request so we can't check it.
      // checkLastRequest();

      check(updateMachine.store.allUsers).unorderedMatches(
        users.map((expected) => (it) => it.fullName.equals(expected.fullName)));
    }));

    test('updates account from snapshot', () => awaitFakeAsync((async) async {
      final account = eg.account(user: eg.selfUser,
        zulipVersion: '6.0+gabcd',
        zulipMergeBase: '6.0',
        zulipFeatureLevel: 123,
      );
      await prepareStore(account: account);
      check(globalStore.getAccount(account.id)).isNotNull()
        ..zulipVersion.equals('6.0+gabcd')
        ..zulipMergeBase.equals('6.0')
        ..zulipFeatureLevel.equals(123);

      globalStore.useCachedApiConnections = true;
      connection.prepare(json: eg.initialSnapshot(
        zulipVersion: '8.0+g9876',
        zulipMergeBase: '8.0',
        zulipFeatureLevel: 234,
      ).toJson());
      final updateMachine = await UpdateMachine.load(globalStore, account.id);
      updateMachine.debugPauseLoop();
      check(globalStore.getAccount(account.id)).isNotNull()
        ..identicalTo(updateMachine.store.account)
        ..zulipVersion.equals('8.0+g9876')
        ..zulipMergeBase.equals('8.0')
        ..zulipFeatureLevel.equals(234);
    }));

    test('retries registerQueue on NetworkError', () => awaitFakeAsync((async) async {
      await prepareStore();

      // Try to load, inducing an error in the request.
      globalStore.useCachedApiConnections = true;
      connection.prepare(httpException: Exception('failed'));
      final future = UpdateMachine.load(globalStore, eg.selfAccount.id);
      bool complete = false;
      unawaited(future.whenComplete(() => complete = true));
      async.flushMicrotasks();
      checkLastRequest();
      check(complete).isFalse();

      // The retry doesn't happen immediately; there's a timer.
      check(async.pendingTimers).length.equals(1);
      async.elapse(Duration.zero);
      check(connection.lastRequest).isNull();
      check(async.pendingTimers).length.equals(1);

      // After a timer, we retry.
      final users = [eg.selfUser, eg.otherUser];
      connection.prepare(json: eg.initialSnapshot(realmUsers: users).toJson());
      final updateMachine = await future;
      updateMachine.debugPauseLoop();
      check(complete).isTrue();
      // checkLastRequest(); TODO UpdateMachine.debugPauseLoop was too late; see comment above
      check(updateMachine.store.allUsers).unorderedMatches(
        users.map((expected) => (it) => it.fullName.equals(expected.fullName)));
    }));

    // TODO test UpdateMachine.load starts polling loop
    // TODO test UpdateMachine.load calls registerNotificationToken
  });

  group('UpdateMachine.fetchEmojiData', () {
    late UpdateMachine updateMachine;
    late PerAccountStore store;
    late FakeApiConnection connection;

    void prepareStore() {
      updateMachine = eg.updateMachine();
      store = updateMachine.store;
      connection = store.connection as FakeApiConnection;
    }

    final emojiDataUrl = Uri.parse('https://cdn.example/emoji.json');
    final data = {
      '1f642': ['slight_smile'],
      '1f34a': ['orange', 'tangerine', 'mandarin'],
    };

    void checkLastRequest() {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('GET')
        ..url.equals(emojiDataUrl)
        ..headers.deepEquals(kFallbackUserAgentHeader);
    }

    test('happy case', () => awaitFakeAsync((async) async {
      prepareStore();
      check(store.debugServerEmojiData).isNull();

      connection.prepare(json: ServerEmojiData(codeToNames: data).toJson());
      await updateMachine.fetchEmojiData(emojiDataUrl);
      checkLastRequest();
      check(store.debugServerEmojiData).deepEquals(data);
    }));

    test('retries on failure', () => awaitFakeAsync((async) async {
      prepareStore();
      check(store.debugServerEmojiData).isNull();

      // Try to fetch, inducing an error in the request.
      connection.prepare(httpException: Exception('failed'));
      final future = updateMachine.fetchEmojiData(emojiDataUrl);
      bool complete = false;
      unawaited(future.whenComplete(() => complete = true));
      async.flushMicrotasks();
      checkLastRequest();
      check(complete).isFalse();
      check(store.debugServerEmojiData).isNull();

      // The retry doesn't happen immediately; there's a timer.
      check(async.pendingTimers).length.equals(1);
      async.elapse(Duration.zero);
      check(connection.lastRequest).isNull();
      check(async.pendingTimers).length.equals(1);

      // After a timer, we retry.
      connection.prepare(json: ServerEmojiData(codeToNames: data).toJson());
      await future;
      check(complete).isTrue();
      checkLastRequest();
      check(store.debugServerEmojiData).deepEquals(data);
    }));
  });

  group('UpdateMachine.poll', () {
    late TestGlobalStore globalStore;
    late PerAccountStore store;
    late UpdateMachine updateMachine;
    late FakeApiConnection connection;

    void updateFromGlobalStore() {
      store = globalStore.perAccountSync(eg.selfAccount.id)!;
      updateMachine = store.updateMachine!;
      connection = store.connection as FakeApiConnection;
    }

    Future<void> preparePoll({int? lastEventId}) async {
      globalStore = eg.globalStore();
      await globalStore.add(eg.selfAccount, eg.initialSnapshot(
        lastEventId: lastEventId));
      await globalStore.perAccount(eg.selfAccount.id);
      updateFromGlobalStore();
      updateMachine.debugPauseLoop();
      updateMachine.poll();
    }

    void checkLastRequest({required int lastEventId}) {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('GET')
        ..url.path.equals('/api/v1/events')
        ..url.queryParameters.deepEquals({
          'queue_id': store.queueId,
          'last_event_id': lastEventId.toString(),
        });
    }

    test('loops on success', () => awaitFakeAsync((async) async {
      await preparePoll(lastEventId: 1);
      check(updateMachine.lastEventId).equals(1);

      // Loop makes first request, and processes result.
      connection.prepare(json: GetEventsResult(events: [
        HeartbeatEvent(id: 2),
      ], queueId: null).toJson());
      updateMachine.debugAdvanceLoop();
      async.flushMicrotasks();
      checkLastRequest(lastEventId: 1);
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(2);

      // Loop makes second request, and processes result.
      connection.prepare(json: GetEventsResult(events: [
        HeartbeatEvent(id: 3),
      ], queueId: null).toJson());
      updateMachine.debugAdvanceLoop();
      async.flushMicrotasks();
      checkLastRequest(lastEventId: 2);
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(3);
    }));

    test('handles events', () => awaitFakeAsync((async) async {
      await preparePoll();

      // Pick some arbitrary event and check it gets processed on the store.
      check(store.userSettings!.twentyFourHourTime).isFalse();
      connection.prepare(json: GetEventsResult(events: [
        UserSettingsUpdateEvent(id: 2,
          property: UserSettingName.twentyFourHourTime, value: true),
      ], queueId: null).toJson());
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(store.userSettings!.twentyFourHourTime).isTrue();
    }));

    void checkReload(FutureOr<void> Function() prepareError, {
      bool expectBackoff = true,
    }) {
      awaitFakeAsync((async) async {
        await preparePoll();
        check(globalStore.perAccountSync(store.accountId)).identicalTo(store);

        await prepareError();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        check(store).isLoading.isTrue();

        if (expectBackoff) {
          // The reload doesn't happen immediately; there's a timer.
          check(globalStore.perAccountSync(store.accountId)).identicalTo(store);
          check(async.pendingTimers).length.equals(1);
          async.flushTimers();
        }

        // The global store has a new store.
        check(globalStore.perAccountSync(store.accountId)).not((it) => it.identicalTo(store));
        updateFromGlobalStore();
        check(store).isLoading.isFalse();

        // The new UpdateMachine updates the new store.
        updateMachine.debugPauseLoop();
        updateMachine.poll();
        check(store.userSettings!.twentyFourHourTime).isFalse();
        connection.prepare(json: GetEventsResult(events: [
          UserSettingsUpdateEvent(id: 2,
            property: UserSettingName.twentyFourHourTime, value: true),
        ], queueId: null).toJson());
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        check(store.userSettings!.twentyFourHourTime).isTrue();
      });
    }

    void checkRetry(void Function() prepareError) {
      awaitFakeAsync((async) async {
        await preparePoll(lastEventId: 1);
        check(async.pendingTimers).length.equals(0);

        // Make the request, inducing an error in it.
        prepareError();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        checkLastRequest(lastEventId: 1);
        check(store).isLoading.isTrue();

        // Polling doesn't resume immediately; there's a timer.
        check(async.pendingTimers).length.equals(1);
        updateMachine.debugAdvanceLoop();
        async.flushMicrotasks();
        check(connection.lastRequest).isNull();
        check(async.pendingTimers).length.equals(1);

        // Polling continues after a timer.
        connection.prepare(json: GetEventsResult(events: [
          HeartbeatEvent(id: 2),
        ], queueId: null).toJson());
        async.flushTimers();
        checkLastRequest(lastEventId: 1);
        check(updateMachine.lastEventId).equals(2);
        check(store).isLoading.isFalse();
      });
    }

    // These cases are ordered by how far the request got before it failed.

    void prepareUnexpectedLoopError() {
      updateMachine.debugPrepareLoopError(eg.nullCheckError());
    }

    void prepareNetworkExceptionSocketException() {
      connection.prepare(httpException: const SocketException('failed'));
    }

    void prepareNetworkException() {
      connection.prepare(httpException: Exception("failed"));
    }

    void prepareServer5xxException() {
      connection.prepare(httpStatus: 500, body: 'splat');
    }

    void prepareMalformedServerResponseException() {
      connection.prepare(httpStatus: 200, body: 'nonsense');
    }

    void prepareRateLimitExceptionCode() {
      // Example from the Zulip API docs:
      //   https://zulip.com/api/rest-error-handling#rate-limit-exceeded
      // (The actual HTTP status should be 429, but that seems undocumented.)
      connection.prepare(httpStatus: 400, json: {
        'result': 'error', 'code': 'RATE_LIMIT_HIT',
        'msg': 'API usage exceeded rate limit',
        'retry-after': 28.706807374954224});
    }

    void prepareRateLimitExceptionStatus() {
      // The HTTP status code for hitting a rate limit,
      // but for some reason a boring BAD_REQUEST error body.
      connection.prepare(httpStatus: 429, json: {
        'result': 'error', 'code': 'BAD_REQUEST', 'msg': 'Bad request'});
    }

    void prepareRateLimitExceptionMalformed() {
      // The HTTP status code for hitting a rate limit,
      // but for some reason a non-JSON body.
      connection.prepare(httpStatus: 429,
        body: '<html><body>An error occurred.</body></html>');
    }

    void prepareZulipApiExceptionBadRequest() {
      connection.prepare(httpStatus: 400, json: {
        'result': 'error', 'code': 'BAD_REQUEST', 'msg': 'Bad request'});
    }

    void prepareExpiredEventQueue() {
      connection.prepare(apiException: eg.apiExceptionBadEventQueueId(
        queueId: store.queueId));
    }

    Future<void> prepareHandleEventError() async {
      final stream = eg.stream();
      await store.addStream(stream);
      // Set up a situation that breaks our data structures' invariants:
      // a stream/channel found in the by-ID map is missing in the by-name map.
      store.streamsByName.remove(stream.name);
      // Then prepare an event on which handleEvent will throw
      // because it hits that broken invariant.
      connection.prepare(json: GetEventsResult(events: [
        ChannelDeleteEvent(id: 1, streams: [stream]),
      ], queueId: null).toJson());
    }

    test('reloads on unexpected error within loop', () {
      checkReload(prepareUnexpectedLoopError);
    });

    test('retries on NetworkException from SocketException', () {
      // We skip reporting errors on these; check we retry them all the same.
      checkRetry(prepareNetworkExceptionSocketException);
    });

    test('retries on generic NetworkException', () {
      checkRetry(prepareNetworkException);
    });

    test('retries on Server5xxException', () {
      checkRetry(prepareServer5xxException);
    });

    test('reloads on MalformedServerResponseException', () {
      checkReload(prepareMalformedServerResponseException);
    });

    test('retries on rate limit: code RATE_LIMIT_HIT', () {
      checkRetry(prepareRateLimitExceptionCode);
    });

    test('retries on rate limit: status 429 ZulipApiException', () {
      checkRetry(prepareRateLimitExceptionStatus);
    });

    test('retries on rate limit: status 429 MalformedServerResponseException', () {
      checkRetry(prepareRateLimitExceptionMalformed);
    });

    test('reloads on generic ZulipApiException', () {
      checkReload(prepareZulipApiExceptionBadRequest);
    });

    test('reloads immediately on expired queue', () {
      checkReload(expectBackoff: false, prepareExpiredEventQueue);
    });

    test('reloads on handleEvent error', () {
      checkReload(prepareHandleEventError);
    });

    group('report error', () {
      String? lastReportedError;
      String? takeLastReportedError() {
        final result = lastReportedError;
        lastReportedError = null;
        return result;
      }

      Future<void> logReportedError(String? message, {String? details}) async {
        if (message == null) return;
        lastReportedError = '$message\n$details';
      }

      Future<void> prepare() async {
        reportErrorToUserBriefly = logReportedError;
        addTearDown(() => reportErrorToUserBriefly = defaultReportErrorToUserBriefly);
        await preparePoll(lastEventId: 1);
      }

      void pollAndFail(FakeAsync async, {bool shouldCheckRequest = true}) {
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        if (shouldCheckRequest) checkLastRequest(lastEventId: 1);
        check(store).isLoading.isTrue();
      }

      Subject<String> checkReported(void Function() prepareError) {
        return awaitFakeAsync((async) async {
          await prepare();
          prepareError();
          // No need to check on the request; there's no later step of this test
          // for it to be needed as setup for.
          pollAndFail(async, shouldCheckRequest: false);
          return check(takeLastReportedError()).isNotNull();
        });
      }

      Subject<String> checkLateReported(void Function() prepareError) {
        return awaitFakeAsync((async) async {
          await prepare();

          for (int i = 0; i < UpdateMachine.transientFailureCountNotifyThreshold; i++) {
            prepareError();
            pollAndFail(async);
            check(takeLastReportedError()).isNull();
            async.flushTimers();
            if (!identical(store, globalStore.perAccountSync(store.accountId))) {
              // Store was reloaded.
              updateFromGlobalStore();
              updateMachine.debugPauseLoop();
              updateMachine.poll();
            }
          }

          prepareError();
          pollAndFail(async);
          return check(takeLastReportedError()).isNotNull();
        });
      }

      void checkNotReported(void Function() prepareError) {
        return awaitFakeAsync((async) async {
          await prepare();

          for (int i = 0; i < UpdateMachine.transientFailureCountNotifyThreshold; i++) {
            prepareError();
            pollAndFail(async);
            check(takeLastReportedError()).isNull();
            async.flushTimers();
            if (!identical(store, globalStore.perAccountSync(store.accountId))) {
              // Store was reloaded.
              updateFromGlobalStore();
              updateMachine.debugPauseLoop();
              updateMachine.poll();
            }
          }

          prepareError();
          pollAndFail(async);
          // Still no error reported, even after the same number of iterations
          // where other errors get reported (as [checkLateReported] checks).
          check(takeLastReportedError()).isNull();
        });
      }

      test('report unexpected error within loop', () {
        checkReported(prepareUnexpectedLoopError);
      });

      test('ignore NetworkException from SocketException', () {
        checkNotReported(prepareNetworkExceptionSocketException);
      });

      test('eventually report generic NetworkException', () {
        checkLateReported(prepareNetworkException).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('eventually report Server5xxException', () {
        checkLateReported(prepareServer5xxException).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report MalformedServerResponseException', () {
        checkReported(prepareMalformedServerResponseException).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report rate limit: code RATE_LIMIT_HIT', () {
        checkLateReported(prepareRateLimitExceptionCode).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report rate limit: status 429 ZulipApiException', () {
        checkLateReported(prepareRateLimitExceptionStatus).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report rate limit: status 429 MalformedServerResponseException', () {
        checkLateReported(prepareRateLimitExceptionMalformed).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report generic ZulipApiException', () {
        checkReported(prepareZulipApiExceptionBadRequest).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('ignore expired queue', () {
        checkNotReported(prepareExpiredEventQueue);
      });

      test('nicely report handleEvent error', () {
        checkReported(prepareHandleEventError).matchesPattern(RegExp(
          r"Error handling a Zulip event\. Retrying connection…\n"
          r"Error handling a Zulip event from \S+; will retry\.\n"
          r"\n"
          r"Error: .*channel\.dart.. Failed assertion.*"
        ));
      });
    });
  });

  group('UpdateMachine.poll reload failure', () {
    late UpdateMachineTestGlobalStore globalStore;

    Future<void> prepareReload(FakeAsync async, {
      required void Function(FakeApiConnection) prepareRegisterQueueResponse,
    }) async {
      globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);

      final store = await globalStore.perAccount(eg.selfAccount.id);
      final updateMachine = store.updateMachine!;

      final connection = store.connection as FakeApiConnection;
      connection.prepare(
        apiException: eg.apiExceptionBadEventQueueId());
      globalStore.prepareRegisterQueueResponse = prepareRegisterQueueResponse;
      // When we reload, we should get a new connection,
      // just like when the app runs live. This is more realistic,
      // and we don't want a glitch where we try to double-close a connection
      // just because of the test infrastructure. (One of the tests
      // logs out the account, and the connection shouldn't be used after that.)
      globalStore.clearCachedApiConnections();
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero); // the bad-event-queue error arrives
      check(store).isLoading.isTrue();
    }

    test('user logged out before new store is loaded', () => awaitFakeAsync((async) async {
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
          json: eg.initialSnapshot().toJson());
      });

      await logOutAccount(globalStore, eg.selfAccount.id);
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));

    test('new store is not loaded, gets HTTP 401 error instead', () => awaitFakeAsync((async) async {
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: Duration(seconds: 1),
          apiException: eg.apiExceptionUnauthorized());
      });

      async.elapse(const Duration(seconds: 1));
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));

    test('new store is not loaded, gets InitialSnapshot with ancient server version', () => awaitFakeAsync((async) async {
      final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: Duration(seconds: 1),
          json: json);
      });

      async.elapse(const Duration(seconds: 1));
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));

    test('new store is not loaded, gets malformed response with ancient server version', () => awaitFakeAsync((async) async {
      final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
      json['realm_emoji'] = 123;
      check(() => InitialSnapshot.fromJson(json)).throws<void>();
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: Duration(seconds: 1),
          json: json);
      });

      async.elapse(const Duration(seconds: 1));
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));
  });

  group('UpdateMachine.registerNotificationToken', () {
    late UpdateMachine updateMachine;
    late FakeApiConnection connection;

    void prepareStore() {
      updateMachine = eg.updateMachine();
      connection = updateMachine.store.connection as FakeApiConnection;
    }

    void checkLastRequestApns({required String token, required String appid}) {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/users/me/apns_device_token')
        ..bodyFields.deepEquals({'token': token, 'appid': appid});
    }

    void checkLastRequestFcm({required String token}) {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/users/me/android_gcm_reg_id')
        ..bodyFields.deepEquals({'token': token});
    }

    testAndroidIos('token already known', () => awaitFakeAsync((async) async {
      // This tests the case where [NotificationService.start] has already
      // learned the token before the store is created.
      // (This is probably the common case.)
      addTearDown(testBinding.reset);
      testBinding.firebaseMessagingInitialToken = '012abc';
      testBinding.packageInfoResult = eg.packageInfo(packageName: 'com.zulip.flutter');
      addTearDown(NotificationService.debugReset);
      await NotificationService.instance.start();

      // On store startup, send the token.
      prepareStore();
      connection.prepare(json: {});
      await updateMachine.registerNotificationToken();
      if (defaultTargetPlatform == TargetPlatform.android) {
        checkLastRequestFcm(token: '012abc');
      } else {
        checkLastRequestApns(token: '012abc', appid: 'com.zulip.flutter');
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        // If the token changes, send it again.
        testBinding.firebaseMessaging.setToken('456def');
        connection.prepare(json: {});
        async.flushMicrotasks();
        checkLastRequestFcm(token: '456def');
      }
    }));

    testAndroidIos('token initially unknown', () => awaitFakeAsync((async) async {
      // This tests the case where the store is created while our
      // request for the token is still pending.
      addTearDown(testBinding.reset);
      testBinding.firebaseMessagingInitialToken = '012abc';
      testBinding.packageInfoResult = eg.packageInfo(packageName: 'com.zulip.flutter');
      addTearDown(NotificationService.debugReset);
      final startFuture = NotificationService.instance.start();

      // TODO this test is a bit brittle in its interaction with asynchrony;
      //   to fix, probably extend TestZulipBinding to control when getToken finishes.
      //
      // The aim here is to first wait for `store.registerNotificationToken`
      // to complete whatever it's going to do; then check no request was made;
      // and only after that wait for `NotificationService.start` to finish,
      // including its `getToken` call.

      // On store startup, send nothing (because we have nothing to send).
      prepareStore();
      await updateMachine.registerNotificationToken();
      check(connection.lastRequest).isNull();

      // When the token later appears, send it.
      connection.prepare(json: {});
      await startFuture;
      async.flushMicrotasks();
      if (defaultTargetPlatform == TargetPlatform.android) {
        checkLastRequestFcm(token: '012abc');
      } else {
        checkLastRequestApns(token: '012abc', appid: 'com.zulip.flutter');
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        // If the token subsequently changes, send it again.
        testBinding.firebaseMessaging.setToken('456def');
        connection.prepare(json: {});
        async.flushMicrotasks();
        checkLastRequestFcm(token: '456def');
      }
    }));

    test('on iOS, use provided app ID from packageInfo', () => awaitFakeAsync((async) async {
      final origTargetPlatform = debugDefaultTargetPlatformOverride;
      addTearDown(() => debugDefaultTargetPlatformOverride = origTargetPlatform);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(testBinding.reset);
      testBinding.firebaseMessagingInitialToken = '012abc';
      testBinding.packageInfoResult = eg.packageInfo(packageName: 'com.example.test');
      addTearDown(NotificationService.debugReset);
      await NotificationService.instance.start();

      prepareStore();
      connection.prepare(json: {});
      await updateMachine.registerNotificationToken();
      checkLastRequestApns(token: '012abc', appid: 'com.example.test');
    }));
  });

  group('ZulipVersionData', () {
    group('fromMalformedServerResponseException', () {
      test('replace missing feature level with 0', () async {
        final connection = testBinding.globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;

        final json = eg.initialSnapshot().toJson()
          ..['zulip_version'] = '2.0.0'
          ..remove('zulip_feature_level') // malformed in current schema
          ..remove('zulip_merge_base');

        Object? error;
        connection.prepare(json: json);
        try {
          await registerQueue(connection);
        } catch (e) {
          error = e;
        }

        check(error).isNotNull().isA<MalformedServerResponseException>();
        final zulipVersionData = ZulipVersionData.fromMalformedServerResponseException(
          error as MalformedServerResponseException);
        check(zulipVersionData).isNotNull()
          ..zulipVersion.equals('2.0.0')
          ..zulipMergeBase.isNull()
          ..zulipFeatureLevel.equals(0);
      });
    });
  });
}

class LoadingTestGlobalStore extends TestGlobalStore {
  LoadingTestGlobalStore({required super.accounts});

  Map<int, List<Completer<PerAccountStore>>> completers = {};

  @override
  Future<PerAccountStore> doLoadPerAccount(int accountId) {
    final completer = Completer<PerAccountStore>();
    (completers[accountId] ??= []).add(completer);
    return completer.future;
  }
}

void testAndroidIos(String description, FutureOr<void> Function() body) {
  test('$description (Android)', body);
  test('$description (iOS)', () async {
    final origTargetPlatform = debugDefaultTargetPlatformOverride;
    addTearDown(() => debugDefaultTargetPlatformOverride = origTargetPlatform);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await body();
  });
}
