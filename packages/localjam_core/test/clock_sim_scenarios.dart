/// The named 60-minute scenarios the clock simulation tests (and the
/// before/after numbers in the 2026-10 clock hardening) run against: real
/// phone Wi-Fi as far as a model can get it — lognormal queueing,
/// power-save spikes, asymmetric congestion, a network that degrades and
/// recovers, one lucky early sample, device sleep — plus the harsher set
/// from the 2026-10-17 adversarial review: correlated and bursty queueing,
/// heavy power save, a fixed path asymmetry, long ping gaps, and clocks
/// whose rate drifts with temperature. Not a test file itself.
library;

import 'package:localjam_core/src/clock/clock_simulation.dart';

const int minuteUs = 60000000;
const int secondUs = 1000000;

/// Heavy power save: one round trip in ten waits 50–300 ms for a beacon.
const SimNetwork powerSaveWifi = SimNetwork(
  spikeProbability: 0.10,
  lossProbability: 0.005,
);

/// 20 s asymmetric congestion bursts every 10 minutes (at 5, 15, … min).
final List<SimNetworkPhase> congestionBursts = [
  for (var m = 5; m < 60; m += 10)
    SimNetworkPhase(
      m * minuteUs,
      m * minuteUs + 20 * secondUs,
      SimNetwork.congestedDownlink,
    ),
];

/// Every scenario, for a relative guest clock rate error of [ppm].
Map<String, ClockSimScenario> clockScenarios(double ppm) => {
  'clean': ClockSimScenario(clockSkewPpm: ppm),
  'luckyEarlySample': ClockSimScenario(
    clockSkewPpm: ppm,
    luckyJoinSample: true,
  ),
  'powerSaveSpikes': ClockSimScenario(
    clockSkewPpm: ppm,
    network: powerSaveWifi,
  ),
  'congestion20s': ClockSimScenario(
    clockSkewPpm: ppm,
    phases: congestionBursts,
  ),
  'goodBadGood': ClockSimScenario(
    clockSkewPpm: ppm,
    phases: const [
      SimNetworkPhase(15 * minuteUs, 35 * minuteUs, SimNetwork.wifiBad),
    ],
  ),
  'sleepMidRun': ClockSimScenario(
    clockSkewPpm: ppm,
    sleeps: const [SimSleep(20 * minuteUs, 2 * minuteUs)],
  ),
  'poisonedBurst': ClockSimScenario(clockSkewPpm: ppm, joinSpikeUs: 200000),
  'badJoin': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.wifiBad,
    phases: const [
      SimNetworkPhase(5 * minuteUs, 60 * minuteUs, SimNetwork.wifiGood),
    ],
  ),
  'combined': ClockSimScenario(
    clockSkewPpm: ppm,
    luckyJoinSample: true,
    phases: [
      ...congestionBursts,
      const SimNetworkPhase(15 * minuteUs, 35 * minuteUs, SimNetwork.wifiBad),
    ],
    sleeps: const [SimSleep(40 * minuteUs, 2 * minuteUs)],
  ),
};

/// The adversarial-review scenarios, for a relative guest clock rate error
/// of [ppm] at join.
Map<String, ClockSimScenario> adversarialScenarios(double ppm) => {
  // 90 % of pongs wait 0–300 ms for a beacon: one clean round trip in ten.
  'heavyPowerSave': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.powerSaveHeavy,
  ),
  // A slow queue stays slow for ~10 round trips.
  'correlatedJitter': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.correlatedJitter,
  ),
  // ~8 s downlink-heavy congestion every ~40 s, all session long.
  'burstyCongestion': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.burstyCongestion,
  ),
  // 1 ms up, 3 ms down: an unobservable −1 ms bias.
  'asymmetricPath': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.asymmetricPath,
  ),
  // Backgrounded for 30 minutes without a ping, playing on.
  'pingGap30min': ClockSimScenario(
    clockSkewPpm: ppm,
    pingGaps: const [SimPingGap(10 * minuteUs, 30 * minuteUs)],
  ),
  // Three 5–15 minute gaps on a power-saving link.
  'pingGapsPowerSave': ClockSimScenario(
    clockSkewPpm: ppm,
    network: powerSaveWifi,
    pingGaps: const [
      SimPingGap(6 * minuteUs, 5 * minuteUs),
      SimPingGap(20 * minuteUs, 15 * minuteUs),
      SimPingGap(45 * minuteUs, 8 * minuteUs),
    ],
  ),
  // Backgrounded for 10 minutes on a heavily power-saving link: the
  // floor learned before the gap must hold after it.
  'pingGapHeavyPowerSave': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.powerSaveHeavy,
    pingGaps: const [SimPingGap(20 * minuteUs, 10 * minuteUs)],
  ),
  // The crystal warms up by 40 ppm over half an hour.
  'temperatureRamp': ClockSimScenario(
    clockSkewPpm: ppm,
    skewChanges: [SimSkewChange(5 * minuteUs, ppm + 40, rampUs: 30 * minuteUs)],
  ),
  // Warming and cooling by ±20 ppm every 10 minutes (a phone moving in and
  // out of a pocket), on bad Wi-Fi.
  'temperatureSwings': ClockSimScenario(
    clockSkewPpm: ppm,
    network: SimNetwork.wifiBad,
    skewChanges: [
      for (var k = 0; k < 5; k++)
        SimSkewChange(
          (5 + 10 * k) * minuteUs,
          ppm + (k.isEven ? 20 : -20),
          rampUs: 10 * minuteUs,
        ),
    ],
  ),
};

/// A 30-minute ping gap during which the clock rate changes by 40 ppm: the
/// offset drifts ~70 ms away from the extrapolation with nothing to notice
/// it, which the first pings after the gap must repair (an unavoidable
/// hard resync).
ClockSimScenario gapWithSkewChange(double ppm) => ClockSimScenario(
  clockSkewPpm: ppm,
  pingGaps: const [SimPingGap(10 * minuteUs, 30 * minuteUs)],
  skewChanges: [SimSkewChange(12 * minuteUs, ppm - 40, rampUs: 2 * minuteUs)],
);
