// Small bell design. Pitch, amplitude, and sustain follow the Godot note API.
SynthDef(\bell, { |out = 0, pitch = 72, amp = 0.14, sustain = 3.0, pan = 0, distance = 0, behind = 0, spatialgain = 1|
    var freq, size, env, sig, partials, amplitudes, sub, stereo, shimmer, airCut, roomMix;
    freq = pitch.midicps;
    size = 1.0;
    env = EnvGen.kr(Env.perc(0.006 * size.sqrt, sustain.max(0.5), curve: -4), doneAction: 2);
    partials = [1, 1.997, 2.706, 3.914, 5.421, 6.817, 8.213, 10.731, 12.412, 15.117];
    amplitudes = [0.58, 0.28, 0.22, 0.16, 0.11, 0.085, 0.06, 0.045, 0.032, 0.022];
    sig = SinOsc.ar(freq * partials, 0, amplitudes).sum;
    sub = SinOsc.ar(freq * [0.5, 0.501], 0, (size - 1).clip(0, 3) * 0.07).sum;
    sig = HPF.ar((sig + sub) * env * amp / size.sqrt, (180 / size).clip(35, 180));
    airCut = (17000 / (1 + (behind * 2.8) + (distance * 0.035))).clip(900, 17000);
    sig = LPF.ar(sig, airCut);
    shimmer = BPF.ar(PinkNoise.ar, (freq * 9).clip(1800, 11000), 0.12) * env.squared * amp * 0.08;
    stereo = Pan2.ar((sig + shimmer) * spatialgain, pan);
    roomMix = (0.14 + (distance * 0.012) + (behind * 0.08)).clip(0.14, 0.42);
    stereo = stereo + (FreeVerb2.ar(stereo[0], stereo[1], roomMix, (0.45 + (size * 0.12)).clip(0.45, 0.88), 0.38) * 0.18);
    Out.ar(out, stereo);
})
