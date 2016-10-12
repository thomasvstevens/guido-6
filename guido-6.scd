//////////////////////////////////
//                              //
//           GUIDO-6            //
//                              //
//     a GUI Digital junO-6     //
//       in SuperCollider       //
//                              //
// Thomas V Stevens, March 2016 //
//                              //
//////////////////////////////////

/*-----------OUTLINE--------------
  1. SynthDefs
         DCO
         LFO
         Mixer
  2. Synths (and Buses)
  3. Play Modes
         Polyphonic
         Monophonic (Portamento)
         Arpeggiator
  4. GUI
         Elements
         Layout
             Main (Arp, LFO, DCO, VCF)
             Aux Controls
             Envelope and Effects
  5. Memory
--------------------------------*/

// Parameters from <https://archive.org/stream/roland_JUNO-6_SERVICE_NOTES/JUNO-6_SERVICE_NOTES_djvu.txt>

(
// FUNCTION DECLARATIONS
var make_synthdefs,make_synths,make_playmodes,make_gui,load_defaults,load_patch,main;

///////////////
// 1. SYNTHDEFS
///////////////
// Globals for VCF cutoff frequency bounds
// Specs say 4 Hz min, but for readability of params, use 1 Hz.
~vcf_cutoff_min=1;
~vcf_cutoff_max=20000;
// Env scaling: specs say 10 octaves max
~vcf_ratio_max=120.midiratio;
// LFO scaling: specs say 6 octaves max
~lfo_ratio_max=72.midiratio;
make_synthdefs = {
    // DCO
    SynthDef.new(\dco,{|out,freq=261.6,mtranspose=0,mslew=16384,
        bend=0,bend_dco=1,bend_vcf=0,
        on_sqr=0,on_saw=0,on_sub=0,amp_sub=0,amp_noise=0,
        bus_pwm,bus_dco_mod,bus_lfo,detune=0,octave=0,
        on_adsr=0,on_pwm_env=0,
        env_a=0.015,env_d=0.233,env_s=0.5,env_r=1,
        vcf_res=0,vcf_ratio=1,vcf_env_ratio=1,vcf_lfo_mod=1,vcf_kybd=1,vcf_polarity=1,
        gate=1|
        var sqr,saw,sub,noise,sig,pwm_in,pwm,env_gate,env_adsr,env,dco_freq,
        cutoff,lfo_cutoff,env_cutoff;
        // Calculate envelopes for availability to controls. Decide gate.
        env_gate = Linen.kr(gate,0.015625,1,0.015625,0);
        env_adsr = EnvGen.kr(Env.adsr(env_a,env_d,env_s,env_r),gate,doneAction:0);
        env = ((1-on_adsr) * env_gate) + (on_adsr * env_adsr);
        // Apply midi-transpose, bend, octave, LFO modulation (1 semitone depth), and detune effects
        freq = freq * mtranspose.midiratio * bend_dco.linlin(0,1,1,bend.midiratio) * (2**octave);
        // Slew rate default to max (2**14) for polyphony, produces portamento for monophony
        freq = Slew.kr(freq.cpsmidi,mslew,mslew).midicps;
        dco_freq = freq * In.kr(bus_dco_mod).linlin(-1,1,(-1).midiratio,1.midiratio);
        dco_freq = [dco_freq * (1-detune), dco_freq * (1+detune)];
        // 0 slider/lfo/env maps to 0.5 pulse width. Full modulation shrinks to silence.
        pwm_in = In.kr(bus_pwm);
        pwm = (((1-on_pwm_env) * pwm_in) + (on_pwm_env * pwm_in * env_adsr)).linlin(-1,1,0,1);
        sqr = Pulse.ar(dco_freq,pwm,on_sqr*0.25);
        saw = Saw.ar(dco_freq,on_saw*0.25);
        sub = Pulse.ar(freq/2,0.5,on_sub*amp_sub*0.25);
        noise = WhiteNoise.ar(amp_noise*0.25);
        // Mix all sources to stereo
        sig = Mix.ar([sqr,saw,sub!2,noise!2]);
        // VCF: keyboard voltage follower sets fundamental, vcf freq slider sets cutoff freq as a ratio to fundamental
        cutoff = vcf_kybd.linlin(0,1,~vcf_cutoff_min,freq) * vcf_ratio;
        env_cutoff = env_adsr.linexp(0,1,1,vcf_env_ratio);
        lfo_cutoff = In.kr(bus_lfo).linexp(-1,1,vcf_lfo_mod.reciprocal,vcf_lfo_mod);
        cutoff = cutoff * env_cutoff.pow(vcf_polarity) * lfo_cutoff;
        cutoff = cutoff * bend_vcf.linlin(0,1,1,bend.midiratio);
        cutoff = cutoff.clip(~vcf_cutoff_min,~vcf_cutoff_max);
        sig = MoogFF.ar(sig, cutoff, vcf_res);
        Out.ar(out, env*sig);
    }).add;
    // LFO
    SynthDef.new(\lfo,{|out,amp,rate=0.3,delay=1.25,gate=1|
        var lfo,env;
        lfo = LFTri.kr(rate,0,amp);
        env = Linen.kr(gate,delay,1,delay,0);
        Out.kr(out,env * lfo)
    }).add;
    // MIXER (HFP, CHORUS, AMP, LIMITER)
    SynthDef.new(\mixer,{|out,in,amp,chorus_level=0,chorus_rate=1,chorus_depth=0,freq_hpf=4|
        var sig;
        // Apply Chorus before HPF
        sig = In.ar(in,2);
        sig = Mix.ar([sig, chorus_level *
            AllpassL.ar(sig,0.05,LFTri.kr(chorus_rate.linexp(0,1,1/8,8),0,0.01*chorus_depth,0.03))!2]);
        // Lag the cutoff frequency to avoid clicks
        sig = HPF.ar(sig, Lag.kr(freq_hpf,0.25));
        // Use a limiter to avoid exceeding audio range (esp. during self-oscillation). Adds 10msec delay.
        Out.ar(out,Limiter.ar(amp!2 * sig,0.95,0.01));
    }).add;
};

////////////
// 2. SYNTHS
////////////
make_synths = {
    MIDIClient.init;
    MIDIIn.connectAll;
    // Bus initialization
    ~bus_out = 0;
    ~bus_dco = Bus.audio;
    ~bus_lfo = Bus.control;
    ~bus_pwm = Bus.control;
    ~bus_pwm_manual = Bus.control.value_(0);
    ~bus_zero = Bus.control.value_(0);
    ~mixer = Synth.new(\mixer, [\out,~bus_out,\in,~bus_dco,\amp,0.5,\freq_hpf,4]);
    // Dynamic Polyphony: limit number of total running synths. This is the 6 in Juno-6?
    ~nkeys = 6;
    ~notes = Array.fill(~nkeys,{|i| Synth.new(\dco,
            [\out,~bus_dco,\bus_dco_mod,~bus_lfo,\bus_pwm,~bus_pwm_manual,\bus_lfo,~bus_lfo,
            \gate,0], addAction:\addToHead)});
    // Start LFO in Auto mode
    ~lfo = Synth.new(\lfo, [\out,~bus_lfo,\gate,0], addAction:\addToHead);
    ~lfo_auto = 1;
    // Bend: +/- 2 semitones
    ~bend = MIDIFunc.bend({|b|
        ~nkeys.do({|i| ~notes[i].set(\bend,b.linlin(0,2**14-1,-2,2))});
    });
};

////////////////
// 3. PLAY MODES
////////////////
make_playmodes = {
    ~noteon;
    ~noteoff;
    ~player;
    // Convenience function to reset player, synths, and MIDIFuncs when switching modes
    ~mode_switch = {
        ~player.stop;
        ~noteon.free;
        ~noteoff.free;
        ~notes.do({|note| note.set(\gate,0)});
    };
    // POLYPHONIC
    ~mode_poly = {
        var free_indices = Array.series(~nkeys);
        var num_note_dict = Dictionary(~nkeys);
        var num_index_dict = Dictionary(~nkeys);
        // NoteOn/NoteOff. Dict maps notenum to synth and array index. Indices are dequeued by noteon, enqueued by noteoff
        ~noteon = MIDIFunc.noteOn({|vel, num|
            var note, index;
            if(free_indices.size>0,{
                index = free_indices.removeAt(0);
                num_index_dict.put(num,index);
                note = ~notes[index];
                num_note_dict.put(num,note);
                note.set(\freq,num.midicps,\gate,1);
                if(~lfo_auto==1,{~lfo.set(\gate,1)});
            });
        });
        ~noteoff = MIDIFunc.noteOff({|vel, num|
            var note;
            if(num_note_dict.at(num)!=nil,{
                note = num_note_dict.removeAt(num);
                free_indices = free_indices.add(num_index_dict.removeAt(num));
                note.set(\gate,0);
                // LFO Auto: if last note released, release LFO
                if(~lfo_auto==1 && num_note_dict.size==0,{~lfo.set(\gate,0)});
            });
        });
    };
    // MONOPHONIC (PORTAMENTO)
    ~mslew_on = 128;
    ~mslew_off = 128**2;
    ~mode_mono = {
        var noteon,noteoff,firstnote=true,keyson=0;
        // only set parameters of first synth
        ~noteon = MIDIFunc.noteOn({|vel, num|
            ~notes[0].set(\freq,num.midicps,\gate,1);
            if(~lfo_auto==1,{~lfo.set(\gate,1)});
            keyson = keyson + 1;
            // start portamento AFTER first key pressed
            if(firstnote,{firstnote=false},{~notes[0].set(\mslew,~mslew_on)});
        });
        ~noteoff = MIDIFunc.noteOff({|vel, num|
            keyson = keyson - 1;
            if(keyson==0,{
                ~notes[0].set(\gate,0);
                if(~lfo_auto==1,{~lfo.set(\gate,0)});
                });
        });
    };
    // ARPEGGIATOR
    ~polarity = "DOWN";
    ~octaves = 1;
    ~mode_arp = {
        var synth,setArp,id_pat,n_notes,pattern,slewpat,last_num,
        startquant = 1/16,
        arpquant = 1,
        pressed = SortedList.new(~nkeys),
        arppat = PatternProxy.new(Pseq([Rest],inf)),
        gatepat = PatternProxy.new(Pn(1));
        arppat.quant_(~octaves);
        gatepat.quant_(~octaves);
        // If monophonic, only use the first synth ID
        if(~on_mono==1,{
            n_notes = 1;
            slewpat = Pseq([Pn(~mslew_off,1),Pn(~mslew_on,inf)]);
        },{
            n_notes = ~nkeys;
            slewpat = Pn(~mslew_off);
        });
        if(~lfo_auto==1,{
            // Set gate simultaneously to LFO and notes
            id_pat = Pstutter(2,Pseq(Array.fill(n_notes, {|i| [~notes[i],~lfo]} ),inf));
        },{
            // Gate notes only, maintain manual LFO
            id_pat = Pstutter(2,Pseq(Array.fill(n_notes, {|i| ~notes[i]} ),inf));
        });
        pattern = Pbind(
            \type, \set,
            \id, id_pat,
            \args, #[\freq, \mslew, \gate],
            \freq, Pstutter(2,arppat.midicps),
            \mslew, Pstutter(2,slewpat),
            \gate, Ppatlace([gatepat,Pn(0)],inf),
            \dur, 1
        );
        ~noteon = MIDIFunc.noteOn({|vel, num|
            pressed.add(num);
            setArp.value(pressed);
            gatepat.source = Pn(1);
            // Start the player if this is the first note since player stopped
            if(~player.isNil or:{~player.isPlaying.not}) {
                // Quantization helps chords start together at slow tempos
                ~player = pattern.play(quant:startquant);
            };
        });
        ~noteoff = MIDIFunc.noteOff({|vel, num|
            last_num = pressed.remove(num);
            // Leave the player running to allow all gates to release. Reinit rest pattern
            if(pressed.isEmpty and:{~player.isPlaying}) {
                arppat.source = Pseq([last_num],inf);
                gatepat.source = Pn(0);
            } {
                // Else update the arppegio pattern
                setArp.value(pressed);
            };
        });
        setArp = {|list|
            var sgn,origlist=list;
            if(~octaves>1) {
                if(~polarity.beginsWith("UP")) {
                    (~octaves-1).do({|i| list = list ++ (origlist+(12*(i+1))) });
                } {
                    (~octaves-1).do({|i| list = (origlist-(12*(i+1))) ++ list });
                }
            };
            switch(~polarity,
                "UP", {list = list;},
                "DOWN", {list = list.reverse;},
                // Mirror1 will return empty list if only 1 item
                "UPDOWN", {if(list.size>1,{list = list.mirror1;},{list});},
                "DOWNUP", {if(list.size>1,{list = list.reverse.mirror1;},{list});}
            );
            arppat.source = Pseq(list,inf)
        };
    };
    // Default Mode: polyphonic (no arp)
    ~mode_poly.value;
    ~on_arp = 0;
    ~on_mono = 0;
    TempoClock.default.tempo_(8);
};
////////////
// 5. MEMORY
////////////
load_patch = {
};

/////////
// 4. GUI
/////////
make_gui = {
    var make_gui_elements,make_gui_layout,load_defaults,
    //--- After testing, move these factory functions inside make_gui_elements()
    make_onoff,make_slider,shift_linexp,shift_explin,
    button_dim=40,slider_dim=40;
    make_onoff = { Button.new.states_([["off",Color.clear,nil],["on",Color.clear,Color.green]])
        .minHeight_(button_dim).maxWidth_(button_dim) };
    make_slider = { Slider.new.maxWidth_(slider_dim) };
    shift_linexp = {|n| n.linexp(0,1,0.01,1.01)-0.01};
    shift_explin = {|n| (n+0.01).explin(0.01,1.01,0,1)};
    //---
    //////////////////
    // A. GUI Elements
    //////////////////
    make_gui_elements = {
        // Each GUI element is a dictionary value with keys: (element,default_p,p->v,v->p) to minimize variable names.
        // Parameters are human readable and settable
        // Value is the element.value, which for sliders is 0-1.
        // default_p is the default parameter to load on GUI creation.
        // p_to_v and v_to_p are initially identity mappings.
        var make_dict;
        make_dict = { |element, default_p, p_to_v=nil, v_to_p=nil|
            if(p_to_v.isNil,{p_to_v={|p| p}});
            if(v_to_p.isNil,{v_to_p={|v| v}});
            (element:element,default_p:default_p,p_to_v:p_to_v,v_to_p:v_to_p).asDict };
        postln("Building ~elements...");
        ~elements = Dictionary();
        //////
        // ARP
        //////
        ~elements.add(\key_transpose -> make_dict.value(
            element: PopUpMenu.new
            .items_(
                Array.fill(13,{|i| (7-i).asString}).put(7,"")
            )
            .action_({ |pop|
                ~nkeys.do({|i| ~notes[i].set(\mtranspose,
                    ~elements[\key_transpose][\v_to_p].value(pop.value)
                )});
            }),
            default_p: 0,
            p_to_v:{|p| 7-p},
            v_to_p:{|v| 7-v}
        ))
        .add(\hold_button -> make_dict.value(
            element: make_onoff.value
            // Use value_(0) to turn off HOLD (esp. during ARP).
            // Using valueAction_ will crash Pbind with empty list.
            .action_({ |b|
                if(b.value==0,{
                    ~mode_switch.value;
                    if(~on_arp==1,{
                        ~mode_arp.value;
                    },{
                        if(~on_mono==1,{
                            ~mode_mono.value;
                        },{
                            ~mode_poly.value;
                        });
                    });
                },{
                    ~noteoff.free;
                });
            }),
            default_p: 0
        ))
        .add(\arp_button -> make_dict.value(
            element: make_onoff.value
            .action_({|b|
                ~mode_switch.value;
                if(b.value==0,{
                    ~on_arp = 0;
                    ~elements[\hold_button][\element].value_(0);
                    ~mode_switch.value;
                    if(~on_mono==1,{~mode_mono.value},{~mode_poly.value});
                },{
                    ~mode_arp.value;
                    ~on_arp = 1;
                });
            }),
            default_p: 0
        ))
        .add(\arp_polarity -> make_dict.value(
            element: PopUpMenu.new
            .items_(["UP","UPDOWN","DOWN","DOWNUP"])
            .action_({|p| ~polarity=p.item;}),
            default_p: "UP",
            p_to_v:{|p| ~elements[\arp_polarity][\element].items.detectIndex({|i| i==p})},
            v_to_p:{|v| ~elements[\arp_polarity][\element].items[v]}
        ))
        .add(\arp_range -> make_dict.value(
            element: PopUpMenu.new
            .items_(["1","2","3"])
            .action_({|p| ~octaves=p.value+1;}),
            default_p: "1",
            p_to_v:{|p| ~elements[\arp_range][\element].items.detectIndex({|i| i==p})},
            v_to_p:{|v| ~elements[\arp_range][\element].items[v]}
        ))
        .add(\arp_rate -> make_dict.value(
            element: make_slider.value
            .action_({ |s|
                TempoClock.default.tempo_(~elements[\arp_rate][\v_to_p].value(s.value));
            }),
            // arp rate = [1.5,50] Hz
            default_p: 8,
            p_to_v: {|p| p.linlin(1.5,50,0,1)},
            v_to_p: {|v| v.linlin(0,1,1.5,50)}
        ));
        postln("\tBuilt ARP...");
        //////
        // LFO
        //////
        ~elements.add(\lfo_rate -> make_dict.value(
            element: make_slider.value
            .action_({ |s|
                ~lfo.set(\rate,~elements[\lfo_rate][\v_to_p].value(s.value));
            }),
            // lfo rate = [0.3,20] Hz
            default_p: 1,
            p_to_v: {|p| p.linlin(0.3,20,0,1)},
            v_to_p: {|v| v.linlin(0,1,0.3,20)}
        ))
        .add(\lfo_delay_time -> make_dict.value(
            element: make_slider.value
            .action_({ |s|
                if(~lfo_auto==0, {~lfo.set(~elements[\lfo_delay_time][\v_to_p].value(s.value))});
            }),
            // delay time = [0,2.5] sec
            default_p: 1,
            p_to_v: {|p| p.linlin(0,2.5,0,1)},
            v_to_p: {|v| v.linlin(0,1,0,2.5)}
        ))
        .add(\lfo_trig_button -> make_dict.value(
            element: make_onoff.value
            .action_({ |b|
                // No effect if auto mode, open the gate in manual mode
                if(~lfo_auto==1, {b.value_(0)}, {~lfo.set(\gate,b.value)});
            })
            .maxWidth_(3*button_dim),
            default_p: 0
        ))
        .add(\lfo_trig_mode -> make_dict.value(
            element: PopUpMenu.new
            .items_(["MAN","AUTO"])
            .action_({ |p|
                // For now, keep lfo_auto global but sync to element value. Used in Play Mode logic.
                ~lfo_auto = p.value;
                // Any setting kills trigger and steals existing gate
                ~lfo.set(\gate,-1);
                ~elements[\lfo_trig_button][\element].valueAction_(0);
                if(~on_arp==1,{
                    ~elements[\hold_button][\element].value_(0);
                    ~mode_switch.value;
                    ~mode_arp.value;
                });
                if(~lfo_auto==1,{
                    // Enter AUTO mode, de-control delay time
                        ~lfo.set(\delay,1);
                },{
                    // Restore delay time from slider
                        ~lfo.set(\delay, ~elements[\lfo_delay_time][\v_to_p].value(
                            ~elements[\lfo_delay_time][\element].value)
                        );
                });
            }),
            default_p: "AUTO",
            p_to_v: {|p| ~elements[\lfo_trig_mode][\element].items.detectIndex({|i| i==p})},
            v_to_p: {|v| ~elements[\lfo_trig_mode][\element].items[v]}
        ));
        postln("\tBuilt LFO...");
        //////
        // DCO
        //////
        ~elements.add(\lfo_depth -> make_dict.value(
            element: make_slider.value
            .action_({ |s| ~lfo.set(\amp,s.value); }),
            default_p: 0
        ))
        .add(\pulse_width -> make_dict.value(
            element: make_slider.value
            .action_({ |s| ~bus_pwm_manual.value_(s.value); }),
            default_p: 0
        ))
        .add(\pwm_bus_menu -> make_dict.value(
            element: PopUpMenu.new
            .items_(["LFO","MAN","ENV"])
            .action_({ |pop|
                // Reset pulsewidth mod envelope parameter
                ~nkeys.do({|i| ~notes[i].set(\on_pwm_env,0)});
                if(pop.item=="MAN",{
                    ~nkeys.do({|i|
                        ~notes[i].set(\bus_pwm,~bus_pwm_manual).set(\bus_dco_mod,~bus_lfo)
                    });
                },{
                    // Kill DCO modulation
                    ~nkeys.do({|i| ~notes[i].set(\bus_dco_mod,~bus_zero)});
                    if(pop.item=="LFO",{
                        ~nkeys.do({|i| ~notes[i].set(\bus_pwm,~bus_lfo)});
                    },{
                        // Use the ADSR envelope generated in the synth
                        ~nkeys.do({|i|
                            ~notes[i].set(\bus_pwm,~bus_pwm_manual).set(\on_pwm_env,1)});
                    });
                });
            }),
            default_p: "MAN",
            p_to_v: {|p| ~elements[\pwm_bus_menu][\element].items.detectIndex({|i| i==p})},
            v_to_p: {|v| ~elements[\pwm_bus_menu][\element].items[v]}
        ))
        .add(\square_button -> make_dict.value(
            element: make_onoff.value
            .action_({ |b| ~nkeys.do({|i| ~notes[i].set(\on_sqr,b.value)}); }),
            default_p: 0
        ))
        .add(\saw_button -> make_dict.value(
            element: make_onoff.value
            .action_({ |b| ~nkeys.do({|i| ~notes[i].set(\on_saw,b.value)}); }),
            default_p: 0
        ))
        .add(\sub_button -> make_dict.value(
            element: make_onoff.value
            .action_({ |b| ~nkeys.do({|i| ~notes[i].set(\on_sub,b.value)}); }),
            default_p: 0
        ))
        .add(\sub_slider -> make_dict.value(
            element: make_slider.value
            .action_({ |s| ~nkeys.do({|i| ~notes[i].set(\amp_sub,s.value)}); }),
            default_p: 0
        ))
        .add(\noise_slider -> make_dict.value(
            element: make_slider.value
            .action_({ |s| ~nkeys.do({|i| ~notes[i].set(\amp_noise,s.value)}); }),
            default_p: 0
        ));
        postln("\tBuilt DCO...");
        //////
        // HPF
        //////
        ~elements.add(\hpf_cutoff -> make_dict.value(
            element: make_slider.value.action_({ |s|
                ~mixer.set(\freq_hpf,~elements[\hpf_cutoff][\v_to_p].value(s.value));
            }),
            // Note: Cutoff frequencies approaching 40kHz yield (infinite amplitude) errors
            default_p: 4,
            p_to_v: {|p| p.explin(4,20000,0,1)},
            v_to_p: {|v| v.linexp(0,1,4,20000)}
        ))
        //////
        // VCF
        //////
        .add(\vcf_ratio -> make_dict.value(
            element: make_slider.value.
            action_({ |s| ~nkeys.do({|i| ~notes[i].set(\vcf_ratio,
                ~elements[\vcf_ratio][\v_to_p].value(s.value))}); }),
            default_p: 1,
            p_to_v: {|p| p.explin(1,(~vcf_cutoff_max/~vcf_cutoff_min),0,1)},
            v_to_p: {|v| v.linexp(0,1,1,(~vcf_cutoff_max/~vcf_cutoff_min))}
        ))
        .add(\resonance -> make_dict.value(
            // Resonance gain is 0 to 4 scale for MoogFF. At 4, self-oscillation occurs.
            element: make_slider.value
                .action_({ |s| ~nkeys.do({|i|
                    ~notes[i].set(\vcf_res, ~elements[\resonance][\v_to_p].value(s.value));
                });
            }),
            default_p: 0,
            p_to_v: {|p| p.linlin(0,4,0,1)},
            v_to_p: {|v| v.linlin(0,1,0,4)}
        ))
        .add(\kybd_follow_frac -> make_dict.value(
            element: make_slider.value
                .action_({|s| ~nkeys.do({|i| ~notes[i].set(\vcf_kybd,s.value)}); }),
            default_p: 1
        ))
        .add(\env_polarity -> make_dict.value(
            element: make_onoff.value
            .states_([["-",Color.white,Color.black], ["+",Color.black,nil]])
            .action_({ |b| ~nkeys.do({|i| ~notes[i].set(\vcf_polarity,
                ~elements[\env_polarity][\v_to_p].value(b.value))}); }),
            default_p: 1,
            p_to_v: {|p| (p+1)/2},
            v_to_p: {|v| 2*v-1}
        ))
        .add(\vcf_env_ratio -> make_dict.value(
            element: make_slider.value
            .action_({ |s| ~nkeys.do({|i| ~notes[i].set(\vcf_env_ratio,
                ~elements[\vcf_env_ratio][\v_to_p].value(s.value))});
            }),
            default_p: 1,
            p_to_v: {|p| p.explin(1,~vcf_ratio_max,0,1)},
            v_to_p: {|v| v.linexp(0,1,1,~vcf_ratio_max)}
        ))
        .add(\vcf_lfo_ratio -> make_dict.value(
            element: make_slider.value
            .action_({ |s| ~nkeys.do({|i| ~notes[i].set(\vcf_lfo_mod,
                ~elements[\vcf_lfo_ratio][\v_to_p].value(s.value))}); }),
            default_p: 1,
            p_to_v: {|p| p.explin(1,~lfo_ratio_max,0,1)},
            v_to_p: {|v| v.linexp(0,1,1,~lfo_ratio_max)}
        ))
    };
    ~elements.postln;
    load_defaults = {
        ~elements.keysValuesDo({|name,dict|
            postln("\t"++name);
            dict[\element].valueAction_(
                dict[\p_to_v].value(dict[\default_p]);
            );
        });
    };
    ////////////////
    // B. GUI Layout
    ////////////////
    make_gui_layout = {
        var make_txt, make_header,
        win_main, win_control, win_env,
        grid_main, grid_control, grid_env,
        screen_arr, bounds_main, bounds_control, bounds_env, scale=1/3;
        // Factory methods for GUI items
        make_header = {
            StaticText.new.background_(Color.black).stringColor_(Color.white).align_(\center).font_(Font.new.pointSize_(18));
        };
        make_txt = { StaticText.new.string_("").align_(\center).font_(Font.new.pointSize_(14)) };
        screen_arr = Window.screenBounds.asArray;
        bounds_main = (screen_arr.copy.put(1,screen_arr[3]) * [1,1,1,2*scale]).asRect;
        ///////////////
        // LAYOUT: MAIN
        ///////////////
        grid_main = GridLayout.columns(
            // ARP
            [nil, make_txt.value.string_("KEY"), ~elements[\key_transpose][\element]],
            [nil, make_txt.value.string_("HOLD"), ~elements[\hold_button][\element]],
            [nil,make_txt.value.string_("ON"), ~elements[\arp_button][\element]],
            [nil,make_txt.value.string_("MODE"), ~elements[\arp_polarity][\element]],
            [nil,make_txt.value.string_("RANGE"),~elements[\arp_range][\element]],
            [nil,make_txt.value.string_("RATE"), ~elements[\arp_rate][\element]],
            // LFO
            [nil,make_txt.value.string_("RATE"), ~elements[\lfo_rate][\element]],
            [nil,make_txt.value.string_("DELAY\nTIME"), ~elements[\lfo_delay_time][\element]],
            [nil,make_txt.value.string_("TRIG\nMODE"), ~elements[\lfo_trig_mode][\element]],
            // DCO
            [nil,make_txt.value.string_("LFO"), ~elements[\lfo_depth][\element]],
            [nil,make_txt.value.string_("PWM"), ~elements[\pulse_width][\element]],
            [nil,make_txt.value, ~elements[\pwm_bus_menu][\element]],
            [nil,make_txt.value.string_("SQR"), ~elements[\square_button][\element]],
            [nil,make_txt.value.string_("SAW"), ~elements[\saw_button][\element]],
            [nil,make_txt.value.string_("SUB"), ~elements[\sub_button][\element]],
            [nil,make_txt.value.string_("SUB\nOSC"), ~elements[\sub_slider][\element]],
            [nil,make_txt.value.string_("NOISE"), ~elements[\noise_slider][\element]],
            // HPF
            [nil,make_txt.value.string_("FREQ"), ~elements[\hpf_cutoff][\element]],
            // VCF
            [nil,make_txt.value.string_("FREQ"), ~elements[\vcf_ratio][\element]],
            [nil,make_txt.value.string_("RES"), ~elements[\resonance][\element]],
            [nil,make_txt.value, ~elements[\env_polarity][\element]],
            [nil,make_txt.value.string_("ENV"), ~elements[\vcf_env_ratio][\element]],
            [nil,make_txt.value.string_("LFO"), ~elements[\vcf_lfo_ratio][\element]],
            [nil,make_txt.value.string_("KYBD"), ~elements[\kybd_follow_frac][\element]]
        );
        // (add headers)
        grid_main.addSpanning(make_header.value.string_("ARPEGGIO"),0,0,1,6);
        grid_main.addSpanning(make_header.value.string_("LFO"),0,6,1,3);
        grid_main.addSpanning(make_header.value.string_("DCO"),0,9,1,8);
        grid_main.add(make_header.value.string_("HPF"),0,17,1,1);
        grid_main.addSpanning(make_header.value.string_("VCF"),0,18,1,6);
        //////////////////
        // LAYOUT: CONTROL
        //////////////////
        grid_control = GridLayout.columns(
            [nil,make_txt.value.string_("DCO"), make_slider.value(1).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\bend_dco,s.value)});
            })],
            [nil,make_txt.value.string_("VCF"), make_slider.value(0).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\bend_vcf,s.value)});
            })],
            [nil,make_txt.value.string_("LFO TRIG"), ~elements[\lfo_trig_button][\element]],
            [nil,make_txt.value.string_("OCTAVE"), PopUpMenu.new.items_(["UP","NORMAL","DOWN"]).value_(1).action_({ |p|
                ~nkeys.do({|i| ~notes[i].set(\octave,1-p.value)})
            }).maxWidth_(button_dim*3)],
            [nil,make_txt.value.string_("VOICES"), make_onoff.value.states_([
                ["POLY",Color.black,nil],["MONO",Color.black,nil]
            ]).value_(0).action_({ |b|
                ~notes[0].set(\mslew,16384);
                ~mode_switch.value;
                ~elements[\hold_button][\element].value_(0);
                if(b.value==0,{
                    ~on_mono = 0;
                    if(~on_arp==1,{
                        ~mode_arp.value;
                    },{
                        ~mode_poly.value;
                    });
                },{
                    ~on_mono = 1;
                    if(~on_arp==1,{
                        ~mode_arp.value;
                    },{
                        ~mode_mono.value;
                    });
                });
            })],
            [nil,make_txt.value.string_("VOLUME"), Knob.new.value_(0.1).action_({ |k|
                ~mixer.set(\amp,k.value.linlin(0,1,0,5))
            }).maxWidth_(button_dim*3)]
        );
        // (add headers)
        grid_control.addSpanning(make_header.value.string_("BEND"),0,0,1,2);
        grid_control.addSpanning(make_header.value.string_(""),0,2,1,3);
        //////////////////
        // LAYOUT: ENV+FX
        //////////////////
        grid_env = GridLayout.columns(
            [nil,make_txt.value.string_(""), make_onoff.value.states_([
                ["GATE",Color.black,nil],["ENV",Color.black,nil]
            ]).action_({ |b|
                ~nkeys.do({|i| ~notes[i].set(\on_adsr,b.value)});
            })],
            // A(0)=1ms A(0.5)=1s, A(1)=3s
            [nil,make_txt.value.string_("A"), make_slider.value(0.01).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\env_a,s.value.lincurve(0.5,1,1,3,0.69415,'nil'))});
            })],
            // D(0)=2ms D(0.5)=1s, D(1)=12s
            [nil,make_txt.value.string_("D"), make_slider.value(0.25).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\env_d,s.value.lincurve(0.5,1,1,12,2.3999,'nil'))});
            })],
            // S is a linear mapping from [0,1]
            [nil,make_txt.value.string_("S"), make_slider.value(0.5).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\env_s,s.value)});
            })],
            // R uses the same mapping function as D
            [nil,make_txt.value.string_("R"), make_slider.value(0.5).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\env_r,s.value.lincurve(0.5,1,1,12,2.3999,'nil'))});
            })],
            // Chorus: guessed at I, II modes
            [nil,make_txt.value.string_("I"), ~chorus_i = make_onoff.value.action_({ |b|
                ~chorus_ii.value_(0);
                ~mixer.set(
                    \chorus_level, b.value * 0.25,
                    \chorus_rate, b.value * 0.25,
                    \chorus_depth, b.value * 0.25,
                );
            })],
            [nil,make_txt.value.string_("II"), ~chorus_ii = make_onoff.value.action_({ |b|
                ~chorus_i.value_(0);
                ~mixer.set(
                    \chorus_level, b.value * 0.5,
                    \chorus_rate, b.value * 0.5,
                    \chorus_depth, b.value * 0.1,
                );
            })],
            // Stereo detuning. Can abuse to simulate amplitude modulation
            [nil,make_txt.value.string_("DETUNE"), make_slider.value(0).action_({ |s|
                ~nkeys.do({|i| ~notes[i].set(\detune,shift_linexp.value(s.value)/2)});
            })],
        );
        // (add headers)
        grid_env.addSpanning(make_header.value.string_("VCA"),0,0,1,1);
        grid_env.addSpanning(make_header.value.string_("ENV"),0,1,1,4);
        grid_env.addSpanning(make_header.value.string_("CHORUS"),0,5,1,3);
        //////////////////
        // MAIN WINDOW
        //////////////////
        win_main = Window.new(bounds:bounds_main).layout_(
            VLayout(
                grid_main,
                HLayout(
                    grid_control,
                    View(),
                    grid_env
                )
            )
        ).front;
    };
    make_gui_elements.value;
    "Made elements.".postln;
    "Loading defaults...".postln;
    load_defaults.value;
    "Making layout...".postln;
    make_gui_layout.value;
    "Made layout.".postln;
};

main = {
    make_synthdefs.value;
    make_synths.value;
    make_playmodes.value;
    "Made backend.".postln;
    make_gui.value;
};

main.value;
)