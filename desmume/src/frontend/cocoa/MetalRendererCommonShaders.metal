/*
	Copyright (C) 2018 DeSmuME team

	This file is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 2 of the License, or
	(at your option) any later version.

	This file is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with the this software.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <metal_stdlib>
using namespace metal;

#include "MetalRendererCommonShaders.h"


float4 unpack_unorm1555_to_unorm8888(const ushort color16)
{
	return float4((float)((color16 >>  0) & 0x1F) / 31.0f,
				  (float)((color16 >>  5) & 0x1F) / 31.0f,
				  (float)((color16 >> 10) & 0x1F) / 31.0f,
				  (float)(color16 >> 15));
}

ushort pack_color_to_unorm5551(const float4 inColor)
{
	ushort4 color16 = (ushort4)((inColor * 31.0f) + 0.35f);
	
	color16.g <<= 5;
	color16.b <<= 10;
	color16.a = (color16.a < 0.0001) ? 0 : 0x8000;
	
	return (color16.r | color16.g | color16.b | color16.a);
}

float4 pack_color_to_unorm6665(const float4 inColor)
{
	return inColor * float4(63.0f/255.0f, 63.0f/255.0f, 63.0f/255.0f, 31.0f/255.0f);
}
