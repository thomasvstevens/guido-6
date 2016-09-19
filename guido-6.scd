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
         Main (Arp, LFO, DCO, VCF)
         Aux Controls
         Envelope and Effects
--------------------------------*/

// Parameters from <https://archive.org/stream/roland_JUNO-6_SERVICE_NOTES/JUNO-6_SERVICE_NOTES_djvu.txt>

(
// FUNCTION DECLARATIONS
var make_synthdefs,make_synths,make_playmodes,make_gui,main;

///////////////
// 1. SYNTHDEFS
///////////////
make_synthdefs = {
    // DCO
    SynthDef.new(\dco,{|out,freq=261.6,mtranspose=0,mslew=16384,
        bend=0,bend_dco=1,bend_vcf=0,
        on_sqr=0,on_saw=0,on_sub=0,amp_sub=0,amp_noise=0,
        bus_pwm,bus_dco_mod,bus_lfo,detune=0,octave=0,
        on_adsr=0,on_pwm_env=0,
        env_a=0.015,env_d=0.233,env_s=0.5,env_r=1,
        vcf_res=0,vcf_cutoff_manual=0,vcf_env_mod=0,vcf_lfo_mod=0,vcf_kybd=1,vcf_polarity=1,
        gate=1|
        var sqr,saw,sub,noise,sig,pwm_in,pwm,env_gate,env_adsr,env,dco_freq,
        cutoff_min=4,cutoff_max=20000,cutoff,lfo_cutoff,env_cutoff;
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
        cutoff = vcf_kybd.linlin(0,1,cutoff_min,freq) * vcf_cutoff_manual.linexp(0,1,1,(cutoff_max/cutoff_min));
        // Env offset: specs say 10 octaves max
        env_cutoff = (env_adsr * vcf_env_mod).linexp(0,1,1,120.midiratio);
        // LFO offset: specs say 6 octaves max
        lfo_cutoff = (vcf_lfo_mod * In.kr(bus_lfo)).linexp(-1,1,(-72).midiratio,72.midiratio);
        cutoff = cutoff * env_cutoff.pow(vcf_polarity) * lfo_cutoff;
        cutoff = cutoff * bend_vcf.linlin(0,1,1,bend.midiratio);
        cutoff = cutoff.clip(cutoff_min,cutoff_max);
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

/////////
// 4. GUI
/////////
make_gui = {
    var make_txt, make_header, make_onoff, make_slider, bdim=40, sdim=40,
    win_main, win_control, win_env,
    grid_main, grid_control, grid_env,
    screen_arr, bounds_main, bounds_control, bounds_env, scale=1/3,
    shift_linexp = {|n| n.linexp(0,1,0.01,1.01)-0.01},
    invert_exp = {|n| (n+0.01).explin(0.01,1.01,0,1)};
    // Factory methods for GUI items
    make_header = {
        StaticText.new.background_(Color.black).stringColor_(Color.white).align_(\center).font_(Font.new.pointSize_(18));
     };
    make_txt = { StaticText.new.string_("").align_(\center).font_(Font.new.pointSize_(14)) };
    make_onoff = { Button.new.states_([["off",Color.clear,nil],
        ["on",Color.clear,Color.green]]).value_(0).minHeight_(bdim).maxWidth_(bdim) };
    make_slider = { |default| Slider.new.value_(default).maxWidth_(sdim) };
    screen_arr = Window.screenBounds.asArray;
    bounds_main = (screen_arr.copy.put(1,screen_arr[3]) * [1,1,1,2*scale]).asRect;
    ///////////////
    // LAYOUT: MAIN
    ///////////////
    grid_main = GridLayout.columns(
        //////
        // ARP
        //////
        [nil,make_txt.value.string_("KEY"), PopUpMenu.new.items_(
            Array.fill(13,{|i| (7-i).asString}).put(7,"");
        ).value_(7).action_({ |p|
            ~nkeys.do({|i| ~notes[i].set(\mtranspose,7-p.value)});
        })],
        [nil,make_txt.value.string_("HOLD"), ~hold_button = make_onoff.value.action_({ |b|
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
        })],
        [nil,make_txt.value.string_("ON"), make_onoff.value.action_({ |b|
            ~mode_switch.value;
            if(b.value==0,{
                ~on_arp = 0;
                ~hold_button.value_(0);
                ~mode_switch.value;
                if(~on_mono==1,{~mode_mono.value},{~mode_poly.value});
            },{
                ~mode_arp.value;
                ~on_arp = 1;
            });
        })],
        [nil,make_txt.value.string_("MODE"), PopUpMenu.new.items_(
            ["UP","UPDOWN","DOWN","DOWNUP"]
            ).value_(2).action_({ |p|
            ~polarity=p.item;
        })],
        [nil,make_txt.value.string_("RANGE"),PopUpMenu.new.items_(["1","2","3"]).value_(0).action_({ |p|
            ~octaves = p.value + 1;
        })],
        // arp rate = [1.5,50] Hz
        [nil,make_txt.value.string_("RATE"), make_slider.value(0.134).action_({ |s|
            TempoClock.default.tempo_(s.value.linlin(0,1,1.5,50));
        })],
        //////
        // LFO
        //////
        // lfo rate = [0.3,20] Hz
        [nil,make_txt.value.string_("RATE"), make_slider.value(0).action_({ |s|
            ~lfo.set(\rate,s.value.linlin(0,1,0.3,20));
        })],
        // delay time = [0,2.5] sec
        [nil,make_txt.value.string_("DELAY\nTIME"), ~slider_delay = make_slider.value(0.5).action_({ |s|
            if(~lfo_auto==0,{~lfo.set(\delay,s.value*2.5)});
        })],
        [nil,make_txt.value.string_("TRIG\nMODE"),PopUpMenu.new.items_(["MAN","AUTO"]).value_(1).action_({ |p|
            ~lfo_auto = p.value;
            // Any setting kills trigger and steals existing gate
            ~lfo.set(\gate,-1);
            ~lfo_trig.value_(0);
            if(~on_arp==1,{
                ~hold_button.value_(0);
                ~mode_switch.value;
                ~mode_arp.value;
            });
            if(~lfo_auto==1,{
                // Enter AUTO mode, de-control delay time
                ~lfo.set(\delay,1);
            },{
                // Restore delay time from slider
                ~lfo.set(\delay,~slider_delay.value);
            });
        })],
        //////
        // DCO
        //////
        [nil,make_txt.value.string_("LFO"), make_slider.value(0).action_({ |s|
            ~lfo.set(\amp,s.value);
        })],
        [nil,make_txt.value.string_("PWM"), make_slider.value(0).action_({ |s|
            ~bus_pwm_manual.value_(s.value);
        })],
        [nil,make_txt.value,PopUpMenu.new.items_(["LFO","MAN","ENV"]).value_(1).action_({ |p|
            // Reset pulsewidth mod envelope parameter
            ~nkeys.do({|i| ~notes[i].set(\on_pwm_env,0)});
            if(p.item=="MAN",{
                ~nkeys.do({|i|
                    ~notes[i].set(\bus_pwm,~bus_pwm_manual).set(\bus_dco_mod,~bus_lfo)
                });
            },{
                // Kill DCO modulation
                ~nkeys.do({|i| ~notes[i].set(\bus_dco_mod,~bus_zero)});
                if(p.item=="LFO",{
                    ~nkeys.do({|i| ~notes[i].set(\bus_pwm,~bus_lfo)});
                },{
                    // Use the ADSR envelope generated in the synth
                    ~nkeys.do({|i|
                        ~notes[i].set(\bus_pwm,~bus_pwm_manual).set(\on_pwm_env,1)});
                });
            });
        })],
        [nil,make_txt.value.string_("SQR"), make_onoff.value.action_({ |b|
            ~nkeys.do({|i| ~notes[i].set(\on_sqr,b.value)});
        })],
        [nil,make_txt.value.string_("SAW"), make_onoff.value.action_({ |b|
            ~nkeys.do({|i| ~notes[i].set(\on_saw,b.value)});
        })],
        [nil,make_txt.value.string_("SUB"), make_onoff.value.action_({ |b|
            ~nkeys.do({|i| ~notes[i].set(\on_sub,b.value)});
        })],
        [nil,make_txt.value.string_("SUB\nOSC"), make_slider.value(0).action_({ |s|
            ~nkeys.do({|i| ~notes[i].set(\amp_sub,s.value)});
        })],
        [nil,make_txt.value.string_("NOISE"), make_slider.value(0).action_({ |s|
            ~nkeys.do({|i| ~notes[i].set(\amp_noise,s.value)});
        })],
        //////
        // HPF
        //////
        // Cutoff frequencies approaching 40kHz yield (infinite amplitude) errors
        [nil,make_txt.value.string_("FREQ"), make_slider.value(0).action_({ |s|
            ~mixer.set(\freq_hpf,s.value.linexp(0,1,4,20000));
        })],
        //////
        // VCF
        //////
        [nil,make_txt.value.string_("FREQ"), make_slider.value(0).action_({ |s|
            ~nkeys.do({|i| ~notes[i].set(\vcf_cutoff_manual,s.value)});
        })],
        [nil,make_txt.value.string_("RES"), make_slider.value(0).action_({ |s|
            // Resonance gain is 0 to 4 scale for MoogFF. At 4, self-oscillation occurs.
            ~nkeys.do({|i| ~notes[i].set(\vcf_res,s.value.linlin(0,1,0,4))});
        })],
        [nil,make_txt.value,make_onoff.value.states_([
            ["-",Color.white,Color.black], ["+",Color.black,nil]
        ]).value_(1).action_({ |b|
            ~nkeys.do({|i| ~notes[i].set(\vcf_polarity,2*b.value-1)});
        })],
        [nil,make_txt.value.string_("ENV"), make_slider.value(0).action_({ |s|
            ~nkeys.do({|i| ~notes[i].set(\vcf_env_mod,shift_linexp.value(s.value))});
        })],
        [nil,make_txt.value.string_("LFO"), make_slider.value(0).action_({ |s|
            ~nkeys.do({|i| ~notes[i].set(\vcf_lfo_mod,shift_linexp.value(s.value))});
        })],
        [nil,make_txt.value.string_("KYBD"), make_slider.value(1).action_({ |s|
            ~nkeys.do({|i| ~notes[i].set(\vcf_kybd,s.value)});
        })]
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
        [nil,make_txt.value.string_("LFO TRIG"), ~lfo_trig = make_onoff.value(0).action_({ |b|
            // No effect if auto mode, open the gate in manual mode
            if(~lfo_auto==1, {b.value_(0)}, {~lfo.set(\gate,b.value)});
        }).maxWidth_(3*bdim)],
        [nil,make_txt.value.string_("OCTAVE"), PopUpMenu.new.items_(["UP","NORMAL","DOWN"]).value_(1).action_({ |p|
            ~nkeys.do({|i| ~notes[i].set(\octave,1-p.value)})
        }).maxWidth_(bdim*3)],
        [nil,make_txt.value.string_("VOICES"), make_onoff.value.states_([
            ["POLY",Color.black,nil],["MONO",Color.black,nil]
        ]).value_(0).action_({ |b|
            ~notes[0].set(\mslew,16384);
            ~mode_switch.value;
            ~hold_button.value_(0);
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
        }).maxWidth_(bdim*3)]
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

main = {
    make_synthdefs.value;
    make_synths.value;
    make_playmodes.value;
    make_gui.value;
};

main.value;
)