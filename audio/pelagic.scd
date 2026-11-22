SynthDef(\pelagic_bed, { |out = 0, pitch = 33, amp = 0.3, water = 0.2, colour = 0, charge = 0, basin = 0, passage = 0|
    var root = Lag.kr(pitch, 2.4).midicps;
    var tide = Lag.kr(water, 1.5);
    var depth = Lag.kr(colour, 3);
    var held = Lag.kr(charge, 0.25);
    var opening = Lag.kr(basin, 3.8);
    var membrane = Lag.kr(passage, 0.57);
    var swell = SinOsc.kr([0.064, 0.078], [0, 1.4]).range(0.52, 1);
    var undertow = SinOsc.ar(root * [0.999, 1.001], [0, 0.31], 0.17 * swell);
    var ratios = [2, 3.001, 4, 5.945] * [1, 1 + (depth * 0.009), 1, 1 + (depth * 0.045)];
    var drift = SinOsc.kr([0.071, 0.114, 0.138, 0.051], [0, 1.9, 4.3, 6]).range(0.24, 1);
    var reeds = VarSaw.ar(root * ratios, [0, 0.28, 0.46, 0.76], 0.44, drift * [0.09, 0.06, 0.044, 0.032]);
    var chord = Splay.ar(LPF.ar(reeds, 350 + (570 * depth) + (390 * tide) + (480 * held)), 0.68);
    var breath = BPF.ar(PinkNoise.ar([1, 1]), [1, 1.45] * (480 + (510 * tide) + (260 * depth)), 0.64);
    var air = breath * (0.021 + (tide * 0.087)) * swell;
    var pearl = SinOsc.ar(root * [12.03, 16.012], SinOsc.ar(root * 3.021, 0, 0.56));
    var glints = pearl * SinOsc.kr([0.12, 0.097], [1.4, 5.1]).range(0, 1).pow(5) * (0.012 + (tide * 0.027));
    var lantern = SinOsc.ar(root * [6.00, 8.018], SinOsc.ar(root * 0.76, 0, 0.23)) *
        SinOsc.kr([0.031, 0.038], [0, 1.8]).range(0.15, 1) * 0.055 * opening;
    var ocean = undertow + chord + air + glints + lantern;
    var passageAir = BPF.ar(PinkNoise.ar([1, 1]), root * [13.05, 16.02], 0.4) * swell * 0.066;
    var body = (ocean * (1 - (0.7 * membrane))) +
        (membrane * (LPF.ar(ocean, 470 + (root * 5)) * 0.7 + passageAir));
    var wet = FreeVerb2.ar(body[0], body[1], 0.63, 0.89, 0.56);
    var fade = EnvGen.kr(Env([0, 1], [2.3], \sine));
    Out.ar(out, HPF.ar(body + (0.44 * wet), 26) * amp * fade);
})

SynthDef(\pelagic_reply, { |out = 0, pitch = 52, amp = 0.22, sustain = 3.2, pan = 0,
        distance = 0, behind = 0, spatialgain = 1|
    var ramp = EnvGen.kr(Env([0.77, 1.04, 0.98], [0.43, 1.12], \sine));
    var env = EnvGen.kr(Env.perc(0.09, sustain.max(0.7), 1, -3.7), doneAction: 2);
    var root = pitch.midicps * ramp;
    var body = SinOsc.ar(root * [1, 1.504, 2.012, 4.091], SinOsc.ar(root * 1.03, 0, [0.16, 0.22, 0.13, 0.11]),
        [0.46, 0.24, 0.18, 0.085]).sum;
    var chime = SinOsc.ar(root * 6.12, 0, 0.13) * env.squared;
    var cut = (7100 / (1 + (0.05 * distance) + (2.5 * behind))).clip(950, 7100);
    var voice = Pan2.ar(LPF.ar((body + chime) * env * amp * spatialgain, cut), pan);
    var room = FreeVerb2.ar(voice[0], voice[1], 0.42, 0.88, 0.48);
    Out.ar(out, HPF.ar(voice + (0.23 * room), 28));
})

SynthDef(\pelagic_call, { |out = 0, pitch = 42, amp = 0.24, sustain = 5, pan = 0|
    var root = pitch.midicps * EnvGen.kr(Env([0.80, 1, 0.87], [0.7, 3.4], \sine));
    var shape = EnvGen.kr(Env.perc(0.26, sustain.max(1), 1, -3), doneAction: 2);
    var partials = SinOsc.ar(root * [1, 2.003, 3.027, 4.09, 7.15],
        SinOsc.ar(root * 1.47, 0, [0, 0.9, 1.6, 1.9, 0.31]), [0.37, 0.31, 0.19, 0.15, 0.074]).sum;
    var foam = BPF.ar(PinkNoise.ar, root * 15, 0.24) * shape.squared * 0.16;
    var voice = Pan2.ar((partials + foam) * shape * amp, pan);
    var water = FreeVerb2.ar(voice[0], voice[1], 0.72, 0.94, 0.43);
    Out.ar(out, HPF.ar(voice + (0.59 * water), 25));
})

SynthDef(\pelagic_signature, { |out = 0, pitch = 60, amp = 0.28, sustain = 4.3, variant = 0|
    var notes = (pitch + [0, 5 + (variant * 2), 12]).midicps;
    var envelopes = [0.003, 0.54, 1.14].collect { |delay|
        EnvGen.kr(Env([0, 0, 1, 0], [delay, 0.096, 2.66], [\lin, \sine, -4.2]));
    };
    var voices = SinOsc.ar(notes, SinOsc.ar(notes * 1.998, 0, 1.12), 0.49) +
        SinOsc.ar(notes * 3.01, 0, 0.085);
    var melody = Splay.ar(voices * envelopes * [1, 0.76, 0.63], 0.56);
    var room = FreeVerb2.ar(melody[0], melody[1], 0.62, 0.91, 0.42);
    var life = Line.kr(1, 0.98, sustain.max(4.2), doneAction: 2);
    Out.ar(out, HPF.ar((melody + (0.48 * room)) * amp * life, 45));
})
