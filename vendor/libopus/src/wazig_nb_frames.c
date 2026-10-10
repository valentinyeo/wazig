/* The one piece of opus_decoder.c the encoder side needs (repacketizer),
   copied verbatim from libopus 1.5.2 so the app links no decoder. */
#include "opus.h"

int opus_packet_get_nb_frames(const unsigned char packet[], opus_int32 len)
{
   int count;
   if (len<1)
      return OPUS_BAD_ARG;
   count = packet[0]&0x3;
   if (count==0)
      return 1;
   else if (count!=3)
      return 2;
   else if (len<2)
      return OPUS_INVALID_PACKET;
   else
      return packet[1]&0x3F;
}
