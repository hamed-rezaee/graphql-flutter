import 'dart:async';
import 'package:meta/meta.dart';

import 'package:graphql/src/core/query_manager.dart';
import 'package:graphql/src/core/query_options.dart';
import 'package:graphql/src/core/fetch_more.dart';
import 'package:graphql/src/core/query_result.dart';
import 'package:graphql/src/core/policies.dart';
import 'package:graphql/src/scheduler/scheduler.dart';

typedef OnData = void Function(QueryResult result);

/// lifecycle states for [ObservableQuery.lifecycle]
enum QueryLifecycle {
  /// No results have been requested or fetched
  unexecuted,

  /// Results are being fetched, and will be side-effect free
  pending,

  /// Polling for results periodically
  polling,

  /// [Observab]
  pollingStopped,

  /// Results are being fetched, and will trigger
  /// the callbacks registered with [ObservableQuery.onData]
  sideEffectsPending,

  /// Pending side effects are preventing [ObservableQuery.close],
  /// and the [ObservableQuery] will be discarded after fetch completes
  /// and side effects are resolved.
  sideEffectsBlocking,

  /// The operation was executed and is not [polling]
  completed,

  /// [ObservableQuery.close] was called and all activity
  /// from this [ObservableQuery] has ceased.
  closed
}

extension DeprecatedQueryLifecycle on QueryLifecycle {
  /// No data has been specified from any source
  @Deprecated(
      'Use `QueryLifecycle.unexecuted` instead. Will be removed in 5.0.0')
  static const UNEXECUTED = QueryLifecycle.unexecuted;

  @Deprecated('Use `QueryLifecycle.pending` instead. Will be removed in 5.0.0')
  static QueryLifecycle get PENDING => QueryLifecycle.pending;

  @Deprecated('Use `QueryLifecycle.polling` instead. Will be removed in 5.0.0')
  static QueryLifecycle get POLLING => QueryLifecycle.polling;

  @Deprecated(
      'Use `QueryLifecycle.pollingStopped` instead. Will be removed in 5.0.0')
  static QueryLifecycle get POLLING_STOPPED => QueryLifecycle.pollingStopped;

  @Deprecated(
      'Use `QueryLifecycle.sideEffectsPending` instead. Will be removed in 5.0.0')
  static QueryLifecycle get SIDE_EFFECTS_PENDING =>
      QueryLifecycle.sideEffectsPending;

  @Deprecated(
      'Use `QueryLifecycle.sideEffectsBlocking` instead. Will be removed in 5.0.0')
  static const SIDE_EFFECTS_BLOCKING = QueryLifecycle.sideEffectsBlocking;

  @Deprecated(
      'Use `QueryLifecycle.completed` instead. Will be removed in 5.0.0')
  static QueryLifecycle get COMPLETED => QueryLifecycle.completed;

  @Deprecated(
      'Use `QueryLifecycle.completed` instead. Will be removed in 5.0.0')
  static QueryLifecycle get CLOSED => QueryLifecycle.closed;
}

/// An Observable/Stream-based API for both queries and mutations.
/// Returned from [GraphQLClient.watchQuery] for use in reactive programming,
/// for instance in `graphql_flutter` widgets.
///
/// [ObservableQuery]'s core api/usage is to [fetchResults], then listen to the [stream].
/// [fetchResults] will be called on instantiation if [options.eagerlyFetchResults] is set,
/// which in turn defaults to [options.fetchResults].
///
/// Beyond that, [ObservableQuery] is a bit of a kitchen sink:
/// * There are [refetch] and [fetchMore] methods for fetching more results
/// * [onData]
///
///
/// It has
///
/// Results can be [refetch]ed,
///
/// It is currently used
/// * [lifecycle] for tracking  polling, side effect, an inflight execution state
/// * [latestResult] – the most recent result from this operation
///
/// Modelled closely after [Apollo's ObservableQuery][apollo_oq]
///
/// [apollo_oq]: https://www.apollographql.com/docs/react/v3.0-beta/api/core/ObservableQuery/
class ObservableQuery {
  ObservableQuery({
    @required this.queryManager,
    @required this.options,
  }) : queryId = queryManager.generateQueryId().toString() {
    if (options.eagerlyFetchResults) {
      _latestWasEagerlyFetched = true;
      fetchResults();
    }
    controller = StreamController<QueryResult>.broadcast(
      onListen: onListen,
    );
  }

  // set to true when eagerly fetched to prevent back-to-back queries
  bool _latestWasEagerlyFetched = false;

  /// The identity of this query within the [QueryManager]
  final String queryId;
  final QueryManager queryManager;

  QueryScheduler get scheduler => queryManager.scheduler;

  final Set<StreamSubscription<QueryResult>> _onDataSubscriptions =
      <StreamSubscription<QueryResult>>{};

  /// The most recently seen result from this operation's stream
  QueryResult latestResult;

  QueryLifecycle lifecycle = QueryLifecycle.unexecuted;

  WatchQueryOptions options;

  StreamController<QueryResult> controller;

  Stream<QueryResult> get stream => controller.stream;
  bool get isCurrentlyPolling => lifecycle == QueryLifecycle.polling;

  bool get _isRefetchSafe {
    switch (lifecycle) {
      case QueryLifecycle.completed:
      case QueryLifecycle.polling:
      case QueryLifecycle.pollingStopped:
        return true;

      case QueryLifecycle.pending:
      case QueryLifecycle.closed:
      case QueryLifecycle.unexecuted:
      case QueryLifecycle.sideEffectsPending:
      case QueryLifecycle.SIDE_EFFECTS_BLOCKING:
        return false;
    }
    return false;
  }

  /// Attempts to refetch, throwing error if not refetch safe
  Future<QueryResult> refetch() {
    if (_isRefetchSafe) {
      return queryManager.refetchQuery(queryId);
    }
    return Future<QueryResult>.error(Exception('Query is not refetch safe'));
  }

  bool get isRebroadcastSafe {
    switch (lifecycle) {
      case QueryLifecycle.pending:
      case QueryLifecycle.completed:
      case QueryLifecycle.polling:
      case QueryLifecycle.pollingStopped:
        return true;

      case QueryLifecycle.unexecuted: // this might be ok
      case QueryLifecycle.closed:
      case QueryLifecycle.sideEffectsPending:
      case QueryLifecycle.sideEffectsBlocking:
        return false;
    }
    return false;
  }

  void onListen() {
    if (_latestWasEagerlyFetched) {
      _latestWasEagerlyFetched = false;

      // eager results are resolved synchronously,
      // so we have to add them manually now that
      // the stream is available
      if (!controller.isClosed && latestResult != null) {
        controller.add(latestResult);
      }
      return;
    }
    if (options.fetchResults) {
      fetchResults();
    }
  }

  MultiSourceResult fetchResults() {
    final MultiSourceResult allResults =
        queryManager.fetchQueryAsMultiSourceResult(queryId, options);
    latestResult ??= allResults.eagerResult;

    // if onData callbacks have been registered,
    // they are waited on by default
    lifecycle = _onDataSubscriptions.isNotEmpty
        ? QueryLifecycle.sideEffectsPending
        : QueryLifecycle.pending;

    if (options.pollInterval != null && options.pollInterval > 0) {
      startPolling(options.pollInterval);
    }

    return allResults;
  }

  /// fetch more results and then merge them with the [latestResult]
  /// according to [FetchMoreOptions.updateQuery].
  ///
  /// The results will then be added to to stream for listeners to react to,
  /// such as for triggering `grahphql_flutter` widget rebuilds
  Future<QueryResult> fetchMore(FetchMoreOptions fetchMoreOptions) async {
    assert(fetchMoreOptions.updateQuery != null);

    addResult(QueryResult.loading(data: latestResult.data));

    return fetchMoreImplementation(
      fetchMoreOptions,
      originalOptions: options,
      queryManager: queryManager,
      previousResult: latestResult,
      queryId: queryId,
    );
  }

  /// add a result to the stream,
  /// copying `loading` and `optimistic`
  /// from the `latestResult` if they aren't set.
  void addResult(QueryResult result) {
    // don't overwrite results due to some async/optimism issue
    if (latestResult != null &&
        latestResult.timestamp.isAfter(result.timestamp)) {
      return;
    }

    if (latestResult != null) {
      result.source ??= latestResult.source;
    }

    if (lifecycle == QueryLifecycle.pending && !result.isOptimistic) {
      lifecycle = QueryLifecycle.completed;
    }

    latestResult = result;

    if (!controller.isClosed) {
      controller.add(result);
    }
  }

  // most mutation behavior happens here
  /// Register [callbacks] to trigger when [stream] has new results
  /// where [QueryResult.isNotLoading]
  ///
  /// Will deregister [callbacks] after calling them on the first
  /// result that [QueryResult.isConcrete],
  /// handling the resolution of [lifecycle] from
  /// [QueryLifecycle.sideEffectsBlocking] to [QueryLifecycle.completed]
  /// as appropriate
  void onData(Iterable<OnData> callbacks) {
    callbacks ??= const <OnData>[];
    StreamSubscription<QueryResult> subscription;

    subscription = stream.where((result) => result.isNotLoading).listen(
      (QueryResult result) async {
        for (final callback in callbacks) {
          await callback(result);
        }

        if (result.isConcrete) {
          await subscription.cancel();
          _onDataSubscriptions.remove(subscription);

          if (_onDataSubscriptions.isEmpty) {
            if (lifecycle == QueryLifecycle.sideEffectsBlocking) {
              lifecycle = QueryLifecycle.completed;
              close();
            }
          }
        }
      },
    );

    _onDataSubscriptions.add(subscription);
  }

  void startPolling(int pollInterval) {
    if (options.fetchPolicy == FetchPolicy.cacheFirst ||
        options.fetchPolicy == FetchPolicy.cacheOnly) {
      throw Exception(
        'Queries that specify the cacheFirst and cacheOnly fetch policies cannot also be polling queries.',
      );
    }

    if (isCurrentlyPolling) {
      scheduler.stopPollingQuery(queryId);
    }

    options.pollInterval = pollInterval;
    lifecycle = QueryLifecycle.polling;
    scheduler.startPollingQuery(options, queryId);
  }

  void stopPolling() {
    if (isCurrentlyPolling) {
      scheduler.stopPollingQuery(queryId);
      options.pollInterval = null;
      lifecycle = QueryLifecycle.pollingStopped;
    }
  }

  set variables(Map<String, dynamic> variables) =>
      options.variables = variables;

  /// [onData] callbacks have het to be run
  ///
  /// inlcudes `lifecycle == QueryLifecycle.sideEffectsBlocking`
  bool get sideEffectsArePending =>
      (lifecycle == QueryLifecycle.sideEffectsPending ||
          lifecycle == QueryLifecycle.sideEffectsBlocking);

  /// Closes the query or mutation, or else queues it for closing.
  ///
  /// To preserve Mutation side effects, [close] checks the [lifecycle],
  /// queuing the stream for closing if  [sideEffectsArePending].
  /// You can override this check with `force: true`.
  ///
  /// Returns a [FutureOr] of the resultant lifecycle, either
  /// [QueryLifecycle.sideEffectsBlocking] or [QueryLifecycle.closed]
  FutureOr<QueryLifecycle> close({
    bool force = false,
    bool fromManager = false,
  }) async {
    if (lifecycle == QueryLifecycle.sideEffectsPending && !force) {
      lifecycle = QueryLifecycle.sideEffectsBlocking;
      // stop closing because we're waiting on something
      return lifecycle;
    }

    // `fromManager` is used by the query manager when it wants to close a query to avoid infinite loops
    if (!fromManager) {
      queryManager.closeQuery(this, fromQuery: true);
    }

    for (StreamSubscription<QueryResult> subscription in _onDataSubscriptions) {
      await subscription.cancel();
    }

    stopPolling();

    await controller.close();

    lifecycle = QueryLifecycle.closed;
    return QueryLifecycle.closed;
  }
}
