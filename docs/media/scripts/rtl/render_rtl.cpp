#include "Vsynth_top.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
struct Event {uint64_t fs; std::array<unsigned,7> s;};
int32_t signed24(uint32_t x){return (x&0x800000)?int32_t(x|0xff000000):int32_t(x);}
void pcm24(std::ofstream& out,int32_t n){for(int i=0;i<3;i++)out.put(char((uint32_t(n)>>(8*i))&255));}
int main(int argc,char**argv){try{
 if(argc!=5 && argc!=6)throw std::runtime_error("usage: render_rtl SCORE FRAMES PCM TEXT [MCLK_HALF_FS]");
 std::ifstream score(argv[1]);if(!score)throw std::runtime_error("score open failed");
 std::vector<Event> events;uint64_t cycle;Event event;
 while(score>>cycle){event.fs=cycle*10000000ULL;for(auto&x:event.s)if(!(score>>x))throw std::runtime_error("bad score");events.push_back(event);}
 const unsigned wanted=std::stoul(argv[2]);
 std::ofstream pcm(argv[3],std::ios::binary),text(argv[4]);if(!pcm||!text)throw std::runtime_error("capture open failed");
 auto context=std::make_unique<VerilatedContext>();context->commandArgs(argc,argv);
 auto dut=std::make_unique<Vsynth_top>(context.get());
 dut->sys_clk=0;dut->mclk=0;dut->sys_rst=1;dut->midi_rx=1;
 dut->cv_sel=0;dut->pitch_cv=0;dut->gate=0;dut->mod_cv=0;
 dut->preset_index=0;dut->preset_recall=0;dut->preset_save=0;
 dut->cfg_wr_en=0;dut->cfg_wr_addr=0;dut->cfg_wr_data=0;dut->cfg_rd_addr=0;
 const uint64_t mclk_half=(argc==6)?std::stoull(argv[5]):40690104ULL;
 uint64_t next_sys=5000000ULL,next_mclk=mclk_half;size_t ei=0;
 unsigned frames=0,count=0,last_ws=0,bits=0,left=0;unsigned max_active=0;
 dut->eval();
 while(frames<wanted+8 && !context->gotFinish()){
  uint64_t now=std::min(next_sys,next_mclk);
  if(ei<events.size())now=std::min(now,events[ei].fs);
  context->time(now);bool old_bclk=dut->codec_bclk;
  while(ei<events.size()&&events[ei].fs==now){auto&s=events[ei++].s;
   dut->sys_rst=s[0];dut->midi_rx=s[1];dut->preset_index=s[2];dut->preset_recall=s[3];
   dut->cfg_wr_en=s[4];dut->cfg_wr_addr=s[5];dut->cfg_wr_data=s[6];}
  if(now==next_sys){dut->sys_clk=!dut->sys_clk;next_sys+=5000000ULL;}
  if(now==next_mclk){dut->mclk=!dut->mclk;next_mclk+=mclk_half;}
  dut->eval();
  if(!old_bclk&&dut->codec_bclk){
   if(dut->sys_rst){last_ws=dut->codec_lrclk;count=0;bits=0;frames=0;}
   else if(dut->codec_lrclk!=last_ws){
    if(last_ws==0)left=bits;
    else{
     if(frames>=8){
      if(count!=24)throw std::runtime_error("invalid I2S bit count");
      int32_t l=signed24(left),r=signed24(bits);pcm24(pcm,l);pcm24(pcm,r);
      text<<frames-8<<' '<<l<<' '<<r<<' '<<unsigned(dut->active)<<'\n';
      unsigned pc=__builtin_popcount(unsigned(dut->active));max_active=std::max(max_active,pc);
      if((frames-8)%48000==0)std::cout<<"Captured "<<frames-8<<" frames"<<std::endl;
     }
     frames++;
    }
    count=0;last_ws=dut->codec_lrclk;
   }else if(count<24){bits=((bits<<1)|dut->sd_tx)&0xffffff;count++;}
  }
 }
 dut->final();if(frames!=wanted+8)throw std::runtime_error("short capture");
 std::cout<<"PASS frames="<<wanted<<" max_active_voices="<<max_active<<std::endl;
 return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
