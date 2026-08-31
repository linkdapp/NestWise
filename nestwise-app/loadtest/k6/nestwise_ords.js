// =============================================================================
// NestWise — k6 load generation against the ORDS REST layer
//
// Run:
//   k6 run -e BASE_URL=http://192.168.56.186:8080/ords/nestwise nestwise_ords.js
//   k6 run -e BASE_URL=... -e PROFILE=stepped  nestwise_ords.js
//   k6 run -e BASE_URL=... -e PROFILE=capture  nestwise_ords.js
//
// Transaction mix mirrors loadtest/swingbench/workload_notes.md exactly, so the
// two load generators drive comparable workloads:
//
//   BrowseNeighborhoods    25%   GET  /neighborhoods/
//   FilterRestaurants      25%   GET  /restaurants/?cuisine=&price_range=&min_rating=
//   ToggleFavorite         15%   POST /neighborhoods/:id/favorite     (the only write)
//   RecommendRestaurants   15%   GET  /restaurants/recommend/:app_user
//   GetNeighborhoodStats   10%   GET  /neighborhoods/:id  + /:id/restaurants
//   SearchNeighborhoods    10%   GET  /neighborhoods/:id/theaters
//
// These handlers call the same PL/SQL packages the APEX pages call, so this is
// NestWise's real database workload -- not a synthetic benchmark. See
// README-k6.md for what this deliberately does NOT cover (APEX page rendering).
// =============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Trend, Rate } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://192.168.56.186:8080/ords/nestwise';
const PROFILE  = __ENV.PROFILE  || 'smoke';

// Think time in milliseconds, min and max, uniform random between them.
// Defaults to the 500-2000ms human pacing specified in
// loadtest/swingbench/workload_notes.md.
//
// The 'saturate' profile overrides this to 50/50 deliberately. Be clear about
// what that changes: with realistic think time you measure query performance
// under a realistic arrival rate; with 50ms you measure how fast the stack can
// be pushed, which is dominated by connection-pool and CPU limits rather than
// SQL. Both are legitimate, but they answer different questions and the numbers
// are not comparable to each other.
const THINK_MIN = Number(__ENV.THINK_MIN || (PROFILE === 'saturate' ? 50  : 500));
const THINK_MAX = Number(__ENV.THINK_MAX || (PROFILE === 'saturate' ? 50  : 2000));

// -----------------------------------------------------------------------------
// Domain values. neighborhood_id is 1-28 and STABLE -- see
// db/oracle/04_neighborhood_id_stability.sql for why that is now guaranteed
// rather than assumed. Cuisines and price ranges are drawn from the real seed.
// -----------------------------------------------------------------------------
const NEIGHBORHOOD_IDS = Array.from({ length: 28 }, (_, i) => i + 1);
const CUISINES = ['Italian', 'American', 'French', 'Mexican', 'Spanish',
                  'Seafood', 'Asian Fusion', 'Belgian', 'Cuban', 'Ethiopian'];
const PRICE_RANGES = ['$', '$$', '$$$', '$$$$'];
const MIN_RATINGS  = [3, 3.5, 4, 4.5];

// A small pool of users, per workload_notes.md: "so ToggleFavorite and
// RecommendRestaurants see realistic per-user state rather than hammering a
// single row." Hammering one row would measure row-level contention, not the
// application.
const APP_USERS = Array.from({ length: 20 }, (_, i) => `LOADUSER${i + 1}`);

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

// -----------------------------------------------------------------------------
// Per-transaction latency, so the write path and the heavy recommend query can
// be read separately from the cheap browse calls. A single aggregate p95 across
// all six would hide exactly the thing worth finding.
// -----------------------------------------------------------------------------
const browseTrend    = new Trend('tx_browse_neighborhoods', true);
const filterTrend    = new Trend('tx_filter_restaurants', true);
const favoriteTrend  = new Trend('tx_toggle_favorite', true);
const recommendTrend = new Trend('tx_recommend_restaurants', true);
const statsTrend     = new Trend('tx_neighborhood_stats', true);
const theatersTrend  = new Trend('tx_list_theaters', true);
const txErrors       = new Rate('tx_errors');

// -----------------------------------------------------------------------------
// Profiles
// -----------------------------------------------------------------------------
const PROFILES = {
    // Prove the endpoints answer. Throw the numbers away.
    smoke: {
        vus: 5,
        duration: '1m',
    },

    // Find the knee: where p95 turns upward. 5 min per step so each reaches
    // steady state -- under ~3 min you are mostly measuring ramp-up.
    stepped: {
        stages: [
            { duration: '30s', target: 10  },
            { duration: '5m',  target: 10  },
            { duration: '30s', target: 25  },
            { duration: '5m',  target: 25  },
            { duration: '30s', target: 50  },
            { duration: '5m',  target: 50  },
            { duration: '30s', target: 100 },
            { duration: '5m',  target: 100 },
            { duration: '30s', target: 0   },
        ],
    },

    // For a RAT Database Replay capture: STEADY, not stepped. Replay reproduces
    // what was captured, so a stepped capture replays as a stepped workload.
    // 15 min sits comfortably inside a pair of manual AWR snapshots and keeps
    // the capture directory small. Run a short warm-up first so the capture
    // reflects steady state rather than cold-cache I/O.
    capture: {
        stages: [
            { duration: '1m',  target: 25 },   // warm-up ramp
            { duration: '15m', target: 25 },   // steady state -- capture this
            { duration: '30s', target: 0  },
        ],
    },

    // Deliberately find a limit. Think time drops to 50ms (see THINK_MIN/MAX
    // above) and concurrency climbs to 1000. Steps are shorter than the
    // 'stepped' profile because the goal here is locating the breaking point,
    // not characterising steady state at each level.
    //
    // PREREQUISITES -- this profile fails immediately without them, see
    // README-k6.md "Pushing to saturation":
    //   1. ulimit -n raised on the k6 host (1000 VUs exhausts the default 1024)
    //   2. ORDS jdbc.MaxLimit raised from its default
    //   3. Oracle `processes` verified to have headroom for the larger pool
    //   4. k6 running somewhere OTHER than the ORDS host, or the load generator
    //      competes for CPU with the thing being measured
    saturate: {
        stages: [
            { duration: '30s', target: 100  },
            { duration: '2m',  target: 100  },
            { duration: '30s', target: 250  },
            { duration: '2m',  target: 250  },
            { duration: '30s', target: 500  },
            { duration: '2m',  target: 500  },
            { duration: '30s', target: 1000 },
            { duration: '3m',  target: 1000 },
            { duration: '30s', target: 0    },
        ],
    },
};

// Fail loudly on an unknown or missing profile. Without this guard, spreading
// an undefined profile leaves `options` with no vus/duration/stages, and k6
// silently falls back to ONE iteration on ONE VU -- reporting success while
// having measured nothing. That looks like a completed run in the terminal and
// is easy to miss.
if (!PROFILES[PROFILE]) {
    throw new Error(
        `Unknown PROFILE "${PROFILE}". Valid values: ${Object.keys(PROFILES).join(', ')}. ` +
        `If you passed a valid name and still see this, the script on this host is ` +
        `probably an older copy that predates that profile -- check the file, not the flag.`
    );
}

export const options = {
    ...PROFILES[PROFILE],
    thresholds: {
        // Fail loudly rather than quietly collecting meaningless numbers.
        http_req_failed: ['rate<0.01'],
        tx_errors:       ['rate<0.01'],
        // Generous ceilings for a demo-scale schema on a home lab. Tighten once
        // you have a baseline -- the point is to catch collapse, not to assert
        // a production SLA.
        'tx_browse_neighborhoods':  ['p(95)<1500'],
        'tx_filter_restaurants':    ['p(95)<1500'],
        'tx_recommend_restaurants': ['p(95)<2500'],  // heaviest read
        'tx_toggle_favorite':       ['p(95)<2000'],  // the write path
    },
};

// -----------------------------------------------------------------------------
// Helper: record one transaction's outcome consistently.
// -----------------------------------------------------------------------------
function record(res, trend, name) {
    trend.add(res.timings.duration);
    const ok = check(res, {
        [`${name}: status ok`]: (r) => r.status === 200 || r.status === 201,
    });
    txErrors.add(!ok);
    return ok;
}

export default function () {
    const roll = Math.random() * 100;
    const nbhd = pick(NEIGHBORHOOD_IDS);
    const user = pick(APP_USERS);

    if (roll < 25) {
        // --- BrowseNeighborhoods (25%) -- the Explorer's default landing state
        group('BrowseNeighborhoods', () => {
            const res = http.get(`${BASE_URL}/neighborhoods/`,
                { tags: { tx: 'browse' } });
            record(res, browseTrend, 'browse');
        });

    } else if (roll < 50) {
        // --- FilterRestaurants (25%) -- Restaurant Finder's dominant query.
        // Params drawn randomly from the seeded domains so the optimizer sees
        // varying selectivity rather than one cached shape.
        group('FilterRestaurants', () => {
            const url = `${BASE_URL}/restaurants/`
                + `?cuisine=${encodeURIComponent(pick(CUISINES))}`
                + `&price_range=${encodeURIComponent(pick(PRICE_RANGES))}`
                + `&min_rating=${pick(MIN_RATINGS)}`;
            const res = http.get(url, { tags: { tx: 'filter' } });
            record(res, filterTrend, 'filter');
        });

    } else if (roll < 65) {
        // --- ToggleFavorite (15%) -- the only write. Exercises the
        // user_favorites MERGE/DELETE and, on RAC, redo and interconnect
        // behaviour. Second call on the same pair un-favorites, which is the
        // real toggle semantics rather than an ever-growing table.
        group('ToggleFavorite', () => {
            const res = http.post(
                `${BASE_URL}/neighborhoods/${nbhd}/favorite`,
                JSON.stringify({ app_user: user }),
                { headers: { 'Content-Type': 'application/json' },
                  tags: { tx: 'favorite' } });
            record(res, favoriteTrend, 'favorite');
        });

    } else if (roll < 80) {
        // --- RecommendRestaurants (15%) -- heaviest read (full scored sort).
        // Isolated from FilterRestaurants because its plan is different.
        group('RecommendRestaurants', () => {
            const res = http.get(`${BASE_URL}/restaurants/recommend/${user}`,
                { tags: { tx: 'recommend' } });
            record(res, recommendTrend, 'recommend');
        });

    } else if (roll < 90) {
        // --- GetNeighborhoodStats (10%) -- Neighborhood Detail's Oracle half.
        // Two calls, as the real page makes: the neighborhood, then its
        // restaurants.
        group('GetNeighborhoodStats', () => {
            const detail = http.get(`${BASE_URL}/neighborhoods/${nbhd}`,
                { tags: { tx: 'stats' } });
            record(detail, statsTrend, 'stats-detail');

            const rest = http.get(`${BASE_URL}/neighborhoods/${nbhd}/restaurants`,
                { tags: { tx: 'stats' } });
            record(rest, statsTrend, 'stats-restaurants');
        });

    } else {
        // --- Theaters (10%) -- Entertainment's Oracle half.
        group('ListTheaters', () => {
            const res = http.get(`${BASE_URL}/neighborhoods/${nbhd}/theaters`,
                { tags: { tx: 'theaters' } });
            record(res, theatersTrend, 'theaters');
        });
    }

    // Think time. Default 0.5-2s uniform random per workload_notes.md; the
    // 'saturate' profile drops it to 50ms. A pure firehose against a
    // 28-neighborhood schema mostly measures connection-pool contention rather
    // than query performance -- which is the point of that profile, but should
    // be labelled as such in any write-up.
    sleep(randomIntBetween(THINK_MIN, THINK_MAX) / 1000);
}

export function handleSummary(data) {
    return {
        'stdout': textSummary(data),
        'summary.json': JSON.stringify(data, null, 2),
    };
}

// Minimal inline summary so the script has no dependency beyond k6-utils.
//
// Note on reading these numbers: k6 Trend metrics expose avg/min/med/max/p(90)/
// p(95) -- there is no sample count, which is why this shows min and max rather
// than an "n" column. Also expect avg to exceed p95 on very short runs: the
// first request of a cold run pays connection setup, hard parse and cold buffer
// cache, and with only a few dozen samples per group that single outlier drags
// the mean above the 95th percentile. That is an artifact of a cold, small
// sample -- one more reason smoke-run numbers get discarded rather than
// recorded.
function textSummary(data) {
    const m = data.metrics;
    const fmt = (n) => (n === undefined ? '     -' : n.toFixed(0).padStart(6));
    const line = (label, key) => {
        const v = m[key];
        if (!v || !v.values) return '';
        return `  ${label.padEnd(26)}`
             + ` avg ${fmt(v.values.avg)} ms`
             + `  p95 ${fmt(v.values['p(95)'])} ms`
             + `  min ${fmt(v.values.min)} ms`
             + `  max ${fmt(v.values.max)} ms\n`;
    };
    let out = '\n=== NestWise ORDS workload ===\n';
    out += line('BrowseNeighborhoods',  'tx_browse_neighborhoods');
    out += line('FilterRestaurants',    'tx_filter_restaurants');
    out += line('ToggleFavorite',       'tx_toggle_favorite');
    out += line('RecommendRestaurants', 'tx_recommend_restaurants');
    out += line('NeighborhoodStats',    'tx_neighborhood_stats');
    out += line('ListTheaters',         'tx_list_theaters');
    const failed = m.http_req_failed?.values?.rate;
    out += `\n  HTTP failure rate         ${failed !== undefined ? (failed * 100).toFixed(2) + '%' : '-'}\n`;
    const reqs = m.http_reqs?.values;
    if (reqs) out += `  Requests                  ${reqs.count} total, ${reqs.rate.toFixed(1)}/s\n`;
    return out + '\n';
}
