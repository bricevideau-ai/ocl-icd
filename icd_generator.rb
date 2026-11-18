=begin
Copyright (c) 2012-2020, Brice Videau <bvideau@anl.gov>
Copyright (c) 2012-2020, Vincent Danjean <Vincent.Danjean@ens-lyon.org>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
=end

require 'yaml'
require 'set'

module IcdGenerator

  $api_entries = {}
  $key_entries = {}
  $api_entries_array = []
  $cl_objects = ["platform_id", "device_id", "context", "command_queue", "mem", "program", "kernel", "event", "sampler"]
  $know_entries = { 1 => "clGetPlatformInfo", 0 => "clGetPlatformIDs", 2 => "clGetDeviceIDs" }
  $use_name_in_test = { 1 => "clGetPlatformInfo", 0 => "clGetPlatformIDs", 2 => "clGetDeviceIDs" }
  # do not call these functions when trying to discover the mapping
  $forbidden_funcs = [
    "clUnloadCompiler", # No parameters so no way to forward to an ICD, OpenCL 1.0
    "clGetPlatformIDs", # Implemented directly within the ICD Loader, not forwarded to ICD
  ]
  # windows function to ignore when loading the database
  $windows_funcs = ["clGetDeviceIDsFromD3D10KHR", "clCreateFromD3D10BufferKHR",
    "clCreateFromD3D10Texture2DKHR", "clCreateFromD3D10Texture3DKHR",
    "clEnqueueAcquireD3D10ObjectsKHR", "clEnqueueReleaseD3D10ObjectsKHR",
    "clGetDeviceIDsFromD3D11KHR", "clCreateFromD3D11BufferKHR",
    "clCreateFromD3D11Texture2DKHR", "clCreateFromD3D11Texture3DKHR",
    "clEnqueueAcquireD3D11ObjectsKHR", "clEnqueueReleaseD3D11ObjectsKHR",
    "clGetDeviceIDsFromDX9MediaAdapterKHR", "clCreateFromDX9MediaSurfaceKHR",
    "clEnqueueAcquireDX9MediaSurfacesKHR", "clEnqueueReleaseDX9MediaSurfacesKHR"]
  # do not create weak functions for these ones in the discovering program
  $noweak_funcs = ["clGetExtensionFunctionAddress", "clGetPlatformIDs",
    "clGetPlatformInfo", "clGetGLContextInfoKHR", "clUnloadCompiler",
    "clCreateContext", "clCreateContextFromType", "clWaitForEvents"]
  # functions written specifically in the loader
  $specific_loader_funcs = ["clGetExtensionFunctionAddress","clGetPlatformIDs",
                         "clGetGLContextInfoKHR", "clUnloadCompiler",
    "clCreateContext", "clCreateContextFromType", "clWaitForEvents"]
  $header_files = ["/usr/include/CL/cl.h", "/usr/include/CL/cl_gl.h", "/usr/include/CL/cl_egl.h",
    "/usr/include/CL/cl_ext.h"]
  $windows_header_files = ["/usr/include/CL/cl_dx9_media_sharing.h", "/usr/include/CL/cl_d3d11.h", "/usr/include/CL/cl_d3d10.h"]
  $cl_data_type_error = { "cl_platform_id"   => "CL_INVALID_PLATFORM",
                          "cl_device_id"     => "CL_INVALID_DEVICE",
                          "cl_context"       => "CL_INVALID_CONTEXT",
                          "cl_command_queue" => "CL_INVALID_COMMAND_QUEUE",
                          "cl_mem"           => "CL_INVALID_MEM_OBJECT",
                          "cl_program"       => "CL_INVALID_PROGRAM",
                          "cl_kernel"        => "CL_INVALID_KERNEL",
                          "cl_event"         => "CL_INVALID_EVENT",
                          "cl_sampler"       => "CL_INVALID_SAMPLER"}
  $non_standard_error = [ "clGetExtensionFunctionAddressForPlatform", "clSVMAlloc" ]
  $versions_entries = []
  $buff=50
  $license = <<EOF
Copyright (c) 2012-2020, Brice Videau <bvideau@anl.gov>
Copyright (c) 2012-2020, Vincent Danjean <Vincent.Danjean@ens-lyon.org>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Do not edit this file. It is automatically generated.
EOF

  ##########################################################
  ##########################################################
  # helper functions
  def self.parse_headers
    api_entries = []
    $header_files.each{ |fname|
      f = File::open(fname)
      doc = f.read
      api_entries += doc.scan(/CL_API_ENTRY.*?;/m)
      f.close
    }
    api_entries.each{ |entry|
#      puts entry
      begin
        entry_name = entry.match(/CL_API_CALL(.*?)\(/m)[1].strip
      rescue
        entry_name = entry.match(/(\S*?)\(/m)[1].strip
      end
      next if entry_name.match('\*')
      next if entry_name.match("INTEL")
      next if entry_name.match("APPLE")
      $api_entries[entry_name] = entry.gsub("\r","")
    }
#    $api_entries.each{ |key, value|
#      puts "#{key}: #{value}"
#    }
  end

  def self.load_database(yamlfile, with_windows=false)
    doc = YAML::load_file(yamlfile)
    $known_entries = {}
    $api_entries ||= {}
    $versions_entries = Hash::new { |hash,key| hash[key]=[] }
    entry_name = ""
    version = ""
    doc.each { |key, value|
      #puts (key.to_s+":: "+value)
      begin
        entry_name = value.match(/CL_API_CALL(.*?)\(/m)[1].strip
      rescue
        entry_name = value.match(/(\S*?)\(/m)[1].strip
      end
      next if (!with_windows) && $windows_funcs.include?(entry_name)
      version = value.match(/SUFFIX__VERSION_(\d_\d)/m)[1]
      $versions_entries[version].push(entry_name)
      $known_entries[key] = entry_name
      $key_entries[entry_name] = key
      $api_entries[entry_name] = value
    }
    $api_entries_array = []
    ($known_entries.length+$buff).times { |i|
      #puts (i.to_s+": "+$known_entries[i])
      if $known_entries[i] then
        $api_entries_array.push( $api_entries[$known_entries[i]] )
      else
        $api_entries_array.push( "CL_API_ENTRY cl_int CL_API_CALL clUnknown#{i}(void);" )
      end
    }
  end

  def self.include_headers
    headers =""
    $header_files.each { |h|
      if h.match('^/usr/include/') then
        headers += "#include <#{h[13..-1]}>\n"
      else
        headers += "#include \"#{h}\"\n"
      end
    }
    return headers
  end

  def self.include_headers_no_warnings
    headers_no_warn = ""
    headers_no_warn << "#pragma GCC diagnostic push\n"
    headers_no_warn << "#  pragma GCC diagnostic ignored \"-Wcpp\"\n"
    headers_no_warn << "#  define CL_USE_DEPRECATED_OPENCL_1_0_APIS\n"
    headers_no_warn << "#  define CL_USE_DEPRECATED_OPENCL_1_1_APIS\n"
    headers_no_warn << "#  define CL_USE_DEPRECATED_OPENCL_1_2_APIS\n"
    headers_no_warn << "#  define CL_USE_DEPRECATED_OPENCL_2_0_APIS\n"
    headers_no_warn << "#  define CL_USE_DEPRECATED_OPENCL_2_1_APIS\n"
    headers_no_warn << "#  define CL_USE_DEPRECATED_OPENCL_2_2_APIS\n"
    headers_no_warn << "#  define CL_TARGET_OPENCL_VERSION 310\n"
    headers_no_warn << "#  include <CL/opencl.h>\n"
    headers_no_warn << self.include_headers
    headers_no_warn << "#pragma GCC diagnostic pop\n"
    headers_no_warn
   end

  ##########################################################
  ##########################################################
  # generate mode
  def self.generate_libdummy_icd_header
    libdummy_icd_structures = "/**\n#{$license}\n*/\n"
    libdummy_icd_structures += "#define CL_TARGET_OPENCL_VERSION 310\n"
    libdummy_icd_structures += "#include <CL/opencl.h>\n"
    libdummy_icd_structures += self.include_headers
    libdummy_icd_structures += "\n\nstruct _cl_icd_dispatch;\n"
    libdummy_icd_structures += "struct _cl_platform_id { struct _cl_icd_dispatch *dispatch; };\n\n"
    libdummy_icd_structures += "struct _cl_icd_dispatch {\n"
    ($api_entries.length+$buff).times { |i|
      if( $known_entries[i] ) then
        libdummy_icd_structures += "  void(*known#{i})(void);\n"
      else
        libdummy_icd_structures += "  void(*unknown#{i})(void);\n"
      end
    }
    libdummy_icd_structures += "};\n\n"
    libdummy_icd_structures += "#pragma GCC visibility push(hidden)\n\n"
    libdummy_icd_structures += "extern struct _cl_icd_dispatch master_dispatch; \n\n"
    libdummy_icd_structures += "#if defined(__APPLE__) || defined(__MACOSX)\n"
    $use_name_in_test.each { |k, f|
      libdummy_icd_structures += "#define INT#{f} #{f}\n"
    }
    libdummy_icd_structures += "#else\n"
    $use_name_in_test.each { |k, f|
      libdummy_icd_structures += "typeof(#{f}) INT#{f};\n"
    }
    libdummy_icd_structures += "#endif\n"
    libdummy_icd_structures += "#pragma GCC visibility pop\n\n"
    return libdummy_icd_structures
  end

  def self.generate_libdummy_icd_source
    libdummy_icd_source = "/**\n#{$license}\n*/\n\n"
    libdummy_icd_source += "#include <stdio.h>\n\n"
    libdummy_icd_source += "#include \"libdummy_icd_gen.h\"\n\n"
    libdummy_icd_source += "#include \"libdummy_icd.h\"\n\n"
    (0...$api_entries.length+$buff).each { |i|
      libdummy_icd_source += "void dummyFunc#{i}(void){ printf(\"#{i}  : \"); fflush(NULL); }\n"
    }
    libdummy_icd_source += "\nstruct _cl_icd_dispatch master_dispatch = {\n"
    comma=","
    ($api_entries.length+$buff).times { |i|
      comma="" if (i == $api_entries.length+$buff-1)
      if( $use_name_in_test[i] ) then
        libdummy_icd_source += "  (void(*)(void))& INT#{$known_entries[i]}#{comma}\n"
      else
        libdummy_icd_source += "  (void(*)(void))& dummyFunc#{i}#{comma}\n"
      end
    }
    libdummy_icd_source += "};\n"
    return libdummy_icd_source
  end

  def self.generate_run_dummy_icd_source
    run_dummy_icd = "/**\n#{$license}\n*/\n"
    run_dummy_icd += "#include <stdlib.h>\n"
    run_dummy_icd += "#include <stdio.h>\n"
    run_dummy_icd += self.include_headers_no_warnings
    run_dummy_icd += "\n\n"
    $api_entries.each_key { |func_name|
       next if $forbidden_funcs.include?(func_name)
       run_dummy_icd += $api_entries[func_name]+"\n"
    }
    run_dummy_icd += "\n\n"
    run_dummy_icd += "void call_all_OpenCL_functions(cl_platform_id chosen_platform) {\n"
    run_dummy_icd += "  cl_context_properties properties[] = { CL_CONTEXT_PLATFORM, (cl_context_properties)chosen_platform, 0 };\n"
    $api_entries.each_key { |func_name|
       next if $forbidden_funcs.include?(func_name)
       if func_name == "clCreateContext" then
         run_dummy_icd += "  #{func_name}(properties,1,(cl_device_id*)&chosen_platform,NULL,NULL,NULL);\n"
       elsif func_name == "clGetGLContextInfoKHR" then
         run_dummy_icd += "  #{func_name}(properties,CL_CURRENT_DEVICE_FOR_GL_CONTEXT_KHR, 0, NULL, NULL);\n"
       elsif func_name == "clCreateContextFromType" then
         run_dummy_icd += "  #{func_name}(properties,CL_DEVICE_TYPE_CPU,NULL,NULL,NULL);\n"
       elsif func_name == "clWaitForEvents" then
         run_dummy_icd += "  #{func_name}(1,(cl_event*)&chosen_platform);\n"
       elsif func_name == "clGetExtensionFunctionAddress" then
         run_dummy_icd += "  #{func_name}(\"extLIG\");\n"
       elsif func_name == "clGetExtensionFunctionAddressForPlatform" then
         run_dummy_icd += "  #{func_name}((cl_platform_id )chosen_platform,\"extLIG\");\n"
       elsif func_name == "clUnloadCompiler" then
         run_dummy_icd += "  #{func_name}();\n"
       else
         params = $api_entries[func_name].gsub(/[[:space:]]+/, ' ')
         params.gsub!(/[\/][*](([^*]*)[*][^\/])*[^*]*[*][\/]/,'')
         params.gsub!(/^[^(]*[(] *(.*[^ ]) *[)][^)]*$/, '\1')
         params = params.gsub(/[^,(]+([(][^)]*[)])*[^,]*/) { |p|
           p.gsub!("[]", "*")
           p.gsub!("user_func", "")
           if false && p.match(/[*]/) then
             "NULL"
           else
             "(#{p})0"
           end
         }
         if func_name != "clGetPlatformIDs" then
           params.gsub!(/^([^0]*)0/, '\1chosen_platform')
         end
         run_dummy_icd += "  #{func_name}(#{params});\n"
       end
       run_dummy_icd += "  printf(\"%s\\n\", \"#{func_name}\");\n"
       run_dummy_icd += "#ifdef OCL_ICD_PRINT_EXPECTED\n"
       run_dummy_icd += "  printf(\"#{$key_entries[func_name]}  : %s (expected)\\n\", \"#{func_name}\");\n"
       run_dummy_icd += "#endif\n"
       run_dummy_icd += "  fflush(NULL);\n"
    }
    run_dummy_icd += "  return;\n}\n"
    return run_dummy_icd
  end

  def self.generate_run_dummy_icd_weak_source
    run_dummy_icd_weak = "/**\n#{$license}\n*/\n"
    run_dummy_icd_weak += <<EOF
#define _GNU_SOURCE 1
#include <stdio.h>
#include <dlfcn.h>

EOF
    run_dummy_icd_weak += self.include_headers_no_warnings

    $api_entries.each { |func_name, entry|
      next if $noweak_funcs.include?(func_name)
      clean_entry = entry.sub(/(.*\)).*/m,'\1').gsub("/*","").gsub("*/","").gsub("\r","") + "{\n"
      return_type = entry.match(/CL_API_ENTRY (.*) CL_API_CALL/)[1]
      parameters = clean_entry.match(/\(.*\)/m)[0][1..-2]
      parameters.gsub!(/\[.*?\]/,"")
      parameters.sub!(/\(.*?\*\s*(.*?)\)\s*\(.*?\)/m,'\1')
      run_dummy_icd_weak += clean_entry.gsub(/\*\[.*?\]/,"*  ").gsub(/\[.+?\]/,"")
      first_parameter = parameters.match(/.*?\,/m)
      if not first_parameter then
        first_parameter =  parameters.match(/.*/m)[0]
      else
        first_parameter = first_parameter[0][0..-2]
      end
      fps = first_parameter.split
      run_dummy_icd_weak += "  void (*p)()=dlsym(RTLD_NEXT, \"#{func_name}\");\n"
      ps = parameters.split(",")
      ps = ps.collect { |p|
        p = p.split
        p = p[-1].gsub("*","")
      }

      run_dummy_icd_weak += "  if(p) {\n"
      run_dummy_icd_weak += "    return((*(typeof(#{func_name})*)p)("
      run_dummy_icd_weak += ps.join(", ")
      run_dummy_icd_weak += "));\n"
      run_dummy_icd_weak += "  } else {\n"
      run_dummy_icd_weak += "    printf(\"-1 : \");\n"
      run_dummy_icd_weak += "    return (#{return_type})0;\n"
      run_dummy_icd_weak += "  }\n"
      run_dummy_icd_weak += "}\n\n"
    }
    return run_dummy_icd_weak
  end

  def self.generate_icd_layer_source
    icd_layer_source = "/**\n#{$license}\n*/\n"
    icd_layer_source += <<EOF
#include <stdio.h>
#include <string.h>
#define CL_USE_DEPRECATED_OPENCL_1_0_APIS
#define CL_USE_DEPRECATED_OPENCL_1_1_APIS
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#define CL_USE_DEPRECATED_OPENCL_2_0_APIS
#define CL_USE_DEPRECATED_OPENCL_2_1_APIS
#define CL_USE_DEPRECATED_OPENCL_2_2_APIS
#define CL_TARGET_OPENCL_VERSION 310
#ifdef HAVE_OPENCL_CL_LAYER_H
#include <OpenCL/cl_layer.h>
#elif defined HAVE_CL_CL_LAYER_H
#include <CL/cl_layer.h>
#else
#include "khronos-headers/CL/cl_layer.h"
#endif

static struct _cl_icd_dispatch dispatch = {NULL};
static const struct _cl_icd_dispatch *tdispatch;
static const cl_layer_api_version layer_api_version = CL_LAYER_API_VERSION_100;
static const char layer_name[] = "dummylayer";

CL_API_ENTRY cl_int CL_API_CALL
clGetLayerInfo(
    cl_layer_info  param_name,
    size_t         param_value_size,
    void          *param_value,
    size_t        *param_value_size_ret) {
  size_t sz = 0;
  const void *src = NULL;
  if (param_value_size && !param_value)
    return CL_INVALID_VALUE;
  if (!param_value && !param_value_size_ret)
    return CL_INVALID_VALUE;
  switch (param_name) {
  case CL_LAYER_API_VERSION:
    sz = sizeof(cl_layer_api_version);
    src = &layer_api_version;
    break;
  case CL_LAYER_NAME:
    sz = sizeof(layer_name);
    src = layer_name;
    break;
  default:
    return CL_INVALID_VALUE;
  }
  if (param_value && param_value_size < sz)
    return CL_INVALID_VALUE;
  if (param_value)
    memcpy(param_value, src, sz);
  if (param_value_size_ret)
    *param_value_size_ret = sz;
  return CL_SUCCESS;
}

static void _init_dispatch(void);

CL_API_ENTRY cl_int CL_API_CALL
clInitLayer(
    cl_uint                         num_entries,
    const struct _cl_icd_dispatch  *target_dispatch,
    cl_uint                        *num_entries_out,
    const struct _cl_icd_dispatch **layer_dispatch) {
  if (!target_dispatch || !layer_dispatch ||!num_entries_out || num_entries < sizeof(dispatch)/sizeof(dispatch.clGetPlatformIDs))
    return -1;

  _init_dispatch();

  tdispatch = target_dispatch;
  *layer_dispatch = &dispatch;
  *num_entries_out = sizeof(dispatch)/sizeof(dispatch.clGetPlatformIDs);
  return CL_SUCCESS;
}

CL_API_ENTRY cl_int CL_API_CALL
clInitLayerWithProperties(
    cl_uint                         num_entries,
    const struct _cl_icd_dispatch  *target_dispatch,
    cl_uint                        *num_entries_out,
    const struct _cl_icd_dispatch **layer_dispatch,
    const cl_layer_properties      *properties) {
  (void)properties;
  if (!target_dispatch || !layer_dispatch ||!num_entries_out || num_entries < sizeof(dispatch)/sizeof(dispatch.clGetPlatformIDs))
    return -1;

  _init_dispatch();

  tdispatch = target_dispatch;
  *layer_dispatch = &dispatch;
  *num_entries_out = sizeof(dispatch)/sizeof(dispatch.clGetPlatformIDs);
  return CL_SUCCESS;
}

CL_API_ENTRY cl_int CL_API_CALL
clDeinitLayer(void) {
  tdispatch = NULL;
  return CL_SUCCESS;
}
EOF

    $api_entries.each { |func_name, entry|
      clean_entry = entry.sub(/(.*\)).*/m,'\1').gsub("/*","").gsub("*/","").gsub("\r","") + "{\n"
      return_type = entry.match(/CL_API_ENTRY (.*) CL_API_CALL/)[1]
      parameters = clean_entry.match(/\(.*\)/m)[0][1..-2]
      parameters.gsub!(/\[.*?\]/,"")
      parameters.sub!(/\(.*?\*\s*(.*?)\)\s*\(.*?\)/m,'\1')
      clean_entry = clean_entry.gsub(func_name, func_name+"_wrap").gsub("CL_API_ENTRY", "").gsub("CL_API_CALL", "")
      icd_layer_source += "static "
      icd_layer_source += clean_entry.gsub(/\*\[.*?\]/,"*  ").gsub(/\[.+?\]/,"")

      ps = parameters.split(",")
      ps = ps.collect { |p|
        p = p.split
        p = p[-1].gsub("*","")
      }
      icd_layer_source += "  printf(\"#{func_name}\\n\");\n"
      icd_layer_source += "  return tdispatch->#{func_name}("
      if func_name != "clUnloadCompiler"
        icd_layer_source += ps.join(", ")
      end
      icd_layer_source += ");\n"
      icd_layer_source += "}\n\n"
    }

    icd_layer_source += "static void _init_dispatch(void) {\n"
    $api_entries.each { |func_name, _|
      icd_layer_source += "  dispatch.#{func_name} = &#{func_name}_wrap;\n"
    }
    icd_layer_source += "}"

    icd_layer_source
  end

  def self.generate_sources(from_headers=true, from_database=false, database=nil)
    if from_headers then
      parse_headers
    end
    if from_database then
      load_database(database)
    end
    File.open('libdummy_icd_gen.h','w') { |f|
      f.puts generate_libdummy_icd_header
    }
    File.open('libdummy_icd_gen.c','w') { |f|
      f.puts generate_libdummy_icd_source
    }
    File.open('run_dummy_icd_gen.c','w') { |f|
      f.puts generate_run_dummy_icd_source
    }
    File.open('run_dummy_icd_weak_gen.c','w') { |f|
      f.puts generate_run_dummy_icd_weak_source
    }
    File.open('dummy_icd_layer_gen.c','w') { |f|
      f.puts generate_icd_layer_source
    }
  end

  ##########################################################
  ##########################################################
  # database mode
  def self.generate_ocl_icd_header
    ocl_icd_header = "/**\n#{$license}\n*/\n\n"
    ocl_icd_header += "#ifndef OCL_ICD_H\n"
    ocl_icd_header += "#define OCL_ICD_H\n"
    ocl_icd_header += self.include_headers_no_warnings
    ocl_icd_header += <<EOF

#define OCL_ICD_API_VERSION	1
#define OCL_ICD_IDENTIFIED_FUNCTIONS	#{$known_entries.count}
#define OCL_ICD_LAST_FUNCTION	#{$known_entries.keys.max}

struct _cl_icd_dispatch {
EOF
    nb=0
    $api_entries_array.each { |entry|
      version = entry.split("\n").
	grep(/ CL_(API|EXT)_SUFFIX__(VERSION_[0-9_]+)[^0-9_]/).join('').
	gsub(/.* CL_(API|EXT)_SUFFIX__(VERSION_[0-9_]*[0-9])_*[^0-9_].*$/, '\2')
      if (version != '') then
	ocl_icd_header += '#ifdef CL_'+version+"\n"
      elsif not entry =~ / clUnknown/
        ocl_icd_header += "#warning no version\n"
      end
      ocl_icd_header += entry.gsub("\r","").
	sub(/CL_API_CALL\n?(.*?)\(/m,'(CL_API_CALL*\1)('+"\n  ").
	gsub(/\) (CL_API_SUFFIX__VERSION)/m,"\n) \\1").gsub(/\s*$/,'').
	gsub(/^[\t ]+/,"    ").gsub(/^([^\t ])/, '  \1') + "\n"
      if (version != '') then
	ocl_icd_header += '#else'+"\n"
	ocl_icd_header += '  CL_API_ENTRY cl_int (CL_API_CALL* clUnknown'+nb.to_s+")(void);\n"
	ocl_icd_header += '#endif'+"\n"
      end
      ocl_icd_header += "\n"
      nb=nb+1
    }
    ocl_icd_header += "};\n"
    ocl_icd_header += "#endif\n\n"
    return ocl_icd_header
  end

  def self.generate_ocl_icd_loader_header
    ocl_icd_header = "/**\n#{$license}\n*/\n\n"
    ocl_icd_header += "#include \"ocl_icd.h\"\n\n"
    ocl_icd_header += <<EOF

struct func_desc {
  const char* name;
  void(*const addr)(void);
};
typedef __typeof__(clGetExtensionFunctionAddress) *clGetExtensionFunctionAddress_fn;
extern const struct func_desc function_description[];
struct vendor_icd {
  cl_uint	num_platforms;
  void *	dl_handle;
  clGetExtensionFunctionAddress_fn ext_fn_ptr;
};

extern struct _cl_icd_dispatch master_dispatch;
extern struct _cl_icd_dispatch deinit_dispatch;
EOF
    $cl_objects.each { |o|
      ocl_icd_header += <<EOF
struct _cl_#{o} {
  struct _cl_icd_dispatch *dispatch;
  struct _cl_disp_data    *disp_data;
};
EOF
    }
    return ocl_icd_header
  end

  def self.generate_ocl_icd_loader_map
    ocl_icd_loader_map = "/**\n#{$license}\n*/\n\n"
    prev_version=""
    $versions_entries.keys.sort.each { |version|
      ocl_icd_loader_map += "OPENCL_#{version.sub('_','.')} {\n";
      ocl_icd_loader_map += "  global:\n";
      $versions_entries[version].each { |symb|
        ocl_icd_loader_map += "    #{symb};\n"
      }
      if (prev_version == "") then
        ocl_icd_loader_map += "  local:\n";
        ocl_icd_loader_map += "    *;\n";
      end
      ocl_icd_loader_map += "} #{prev_version};\n\n";
      prev_version="OPENCL_#{version.sub('_','.')}";
    }
    return ocl_icd_loader_map
  end

  def self.generate_ocl_icd_bindings_source
    ocl_icd_bindings_source = "/**\n#{$license}\n*/\n"
    ocl_icd_bindings_source += "#include \"ocl_icd.h\"\n"
    ocl_icd_bindings_source += "struct _cl_icd_dispatch master_dispatch = {\n"
    ($api_entries.length+$buff-1).times { |i|
      if( $known_entries[i] ) then
        ocl_icd_bindings_source += "  #{$known_entries[i]},\n"
      else
        ocl_icd_bindings_source += "  (void *) NULL,\n"
      end
    }
    if( $known_entries[$api_entries.length+$buff-1] ) then
      ocl_icd_bindings_source += "  #{$known_entries[$api_entries.length+$buff-1]}\n"
    else
      ocl_icd_bindings_source += "  (void *) NULL\n"
    end
    ocl_icd_bindings_source += "};\n"
    ocl_icd_bindings_source += <<EOF

CL_API_ENTRY cl_int CL_API_CALL clIcdGetPlatformIDsKHR(
             cl_uint num_entries,
             cl_platform_id *platforms,
             cl_uint *num_platforms) {
  if( platforms == NULL && num_platforms == NULL )
    return CL_INVALID_VALUE;
  if( num_entries == 0 && platforms != NULL )
    return CL_INVALID_VALUE;
#error You have to fill the commented lines with corresponding variables from your library
//  if( your_number_of_platforms == 0)
//    return CL_PLATFORM_NOT_FOUND_KHR;
//  if( num_platforms != NULL )
//    *num_platforms = your_number_of_platforms;
  if( platforms != NULL ) {
    cl_uint i;
//    for( i=0; i<(your_number_of_platforms<num_entries?your_number_of_platforms:num_entries); i++)
//      platforms[i] = &your_platforms[i];
  }
  return CL_SUCCESS;
}

CL_API_ENTRY void * CL_API_CALL clGetExtensionFunctionAddress(
             const char *   func_name) CL_API_SUFFIX__VERSION_1_0 {
#error You have to fill this function with your extensions of incorporate these lines in your version
  if( func_name != NULL &&  strcmp("clIcdGetPlatformIDsKHR", func_name) == 0 )
    return (void *)clIcdGetPlatformIDsKHR;
  return NULL;
}
CL_API_ENTRY cl_int CL_API_CALL clGetPlatformInfo(
             cl_platform_id   platform,
             cl_platform_info param_name,
             size_t           param_value_size,
             void *           param_value,
             size_t *         param_value_size_ret) CL_API_SUFFIX__VERSION_1_0 {
#error You ahve to fill this function with your information or assert that your version responds to CL_PLATFORM_ICD_SUFFIX_KHR
//  char cl_platform_profile[] = "FULL_PROFILE";
//  char cl_platform_version[] = "OpenCL 1.1";
//  char cl_platform_name[] = "DummyCL";
//  char cl_platform_vendor[] = "LIG";
//  char cl_platform_extensions[] = "cl_khr_icd";
//  char cl_platform_icd_suffix_khr[] = "DUMMY";
  size_t size_string;
  char * string_p;
  if( platform != NULL ) {
    int found = 0;
    int i;
    for(i=0; i<num_master_platforms; i++) {
      if( platform == &master_platforms[i] )
        found = 1;
    }
    if(!found)
      return CL_INVALID_PLATFORM;
  }
  switch ( param_name ) {
    case CL_PLATFORM_PROFILE:
      string_p = cl_platform_profile;
      size_string = sizeof(cl_platform_profile);
      break;
    case CL_PLATFORM_VERSION:
      string_p = cl_platform_version;
      size_string = sizeof(cl_platform_version);
      break;
    case CL_PLATFORM_NAME:
      string_p = cl_platform_name;
      size_string = sizeof(cl_platform_name);
      break;
    case CL_PLATFORM_VENDOR:
      string_p = cl_platform_vendor;
      size_string = sizeof(cl_platform_vendor);
      break;
    case CL_PLATFORM_EXTENSIONS:
      string_p = cl_platform_extensions;
      size_string = sizeof(cl_platform_extensions);
      break;
    case CL_PLATFORM_ICD_SUFFIX_KHR:
      string_p = cl_platform_icd_suffix_khr;
      size_string = sizeof(cl_platform_icd_suffix_khr);
      break;
    default:
      return CL_INVALID_VALUE;
      break;
  }
  if( param_value != NULL ) {
    if( size_string > param_value_size )
      return CL_INVALID_VALUE;
    memcpy(param_value, string_p, size_string);
  }
  if( param_value_size_ret != NULL )
    *param_value_size_ret = size_string;
  return CL_SUCCESS;
}
EOF
    return ocl_icd_bindings_source
  end

  def self.generate_get_extension_address_for_platform
    src = <<EOF
  if( func_name == NULL )
    return NULL;
  struct func_desc const * fn=&function_description[0];
  int lenfn=strlen(func_name);
  if (lenfn > 3 &&
      (strcmp(func_name+lenfn-3, "KHR")==0 || strcmp(func_name+lenfn-3, "EXT")==0)) {
    while (fn->name != NULL) {
      if (strcmp(func_name, fn->name)==0)
        RETURN(fn->addr);
      fn++;
    }
  }
EOF
    return src
  end

  def self.generate_ocl_icd_loader_gen_source
    skip_funcs = $specific_loader_funcs
    ocl_icd_loader_gen_source = <<EOF
/**\n#{$license}\n*/
#include <string.h>
#include "ocl_icd_loader.h"
#define DEBUG_OCL_ICD_PROVIDE_DUMP_FIELD
#include "ocl_icd_debug.h"
#define hidden_alias(name) \\
  typeof(name) name##_hid __attribute__ ((alias (#name), visibility("hidden")))

EOF
    cleanup = proc { |entry|
      clean_entry = entry.sub(/(.*\)).*/m,'\1').gsub("/*","").gsub("*/","").gsub("\r","") + "{\n"
      return_type = entry.match(/CL_API_ENTRY (.*) CL_API_CALL/)[1]
      parameters = clean_entry.match(/\(.*\)/m)[0][1..-2]
      parameters.gsub!(/\[.*?\]/,"")
      parameters.sub!(/\(.*?\*\s*(.*?)\)\s*\(.*?\)/m,'\1')
      ps = parameters.split(",")
      ps = ps.collect { |p|
        p = p.split
        p = p[-1].gsub("*","")
      }
      [clean_entry, return_type, parameters, ps]
    }
    api_stub = proc { |(func_name, entry)|
      clean_entry, return_type, parameters, ps = cleanup.call(entry)
      clean_entry = clean_entry.gsub(func_name, func_name+"_unsupp").gsub("CL_API_ENTRY", "")
      ocl_icd_loader_gen_source +=  'static '
      ocl_icd_loader_gen_source += clean_entry.gsub(/\*\[.*?\]/,"*  ").gsub(/\[.+?\]/,"")
      if(ps.include?("errcode_ret")) then
        ocl_icd_loader_gen_source += "  if( errcode_ret != NULL ) {\n";
        ocl_icd_loader_gen_source += "    *errcode_ret = CL_INVALID_OPERATION;\n"
        ocl_icd_loader_gen_source += "  }\n"
        if return_type != "void" then
          ocl_icd_loader_gen_source += "  RETURN(NULL);\n"
        else
          ocl_icd_loader_gen_source += "  return;\n"
        end
      elsif ($non_standard_error.include?(func_name)) then
        if return_type != "void" then
          ocl_icd_loader_gen_source += "  RETURN(NULL);\n"
        else
          ocl_icd_loader_gen_source += "  return;\n"
        end
      elsif func_name == "clGetExtensionFunctionAddress"
          ocl_icd_loader_gen_source += "  return NULL;\n"
      else
        if return_type != "void" then
          ocl_icd_loader_gen_source += "  RETURN(CL_INVALID_OPERATION);\n" if return_type != "void"
        else
          ocl_icd_loader_gen_source += "  return;\n"
        end
      end
      ocl_icd_loader_gen_source += "}\n\n"
    }
    api_proc = proc { |disp, (func_name, entry)|
      next if skip_funcs.include?(func_name)
      clean_entry, return_type, parameters, ps = cleanup.call(entry)
      if disp
        clean_entry = clean_entry.gsub(func_name, func_name+"_disp").gsub("CL_API_ENTRY", "").gsub("CL_API_CALL", "")
        ocl_icd_loader_gen_source +=  '__attribute__((visibility("hidden"))) '
      end
      ocl_icd_loader_gen_source += clean_entry.gsub(/\*\[.*?\]/,"*  ").gsub(/\[.+?\]/,"")
      first_parameter = parameters.match(/.*?\,/m)
      if not first_parameter then
        first_parameter =  parameters.match(/.*/m)[0]
      else
        first_parameter = first_parameter[0][0..-2]
      end
      fps = first_parameter.split
      if !disp
        ocl_icd_loader_gen_source += "  debug_trace();\n"
        ocl_icd_loader_gen_source += "  _initClIcd_no_inline();\n" if fps[0] == "cl_platform_id"
        ocl_icd_loader_gen_source += "  if (_first_layer)\n"
        ocl_icd_loader_gen_source += "    return _first_layer->dispatch.#{func_name}("
        ocl_icd_loader_gen_source += ps.join(", ")
        ocl_icd_loader_gen_source += ");\n"
      end
      ocl_icd_loader_gen_source += generate_get_extension_address_for_platform if func_name == "clGetExtensionFunctionAddressForPlatform"
      raise "Unsupported data_type #{fps[0]}" if ! $cl_data_type_error[fps[0]]
      error_handler = lambda {
        if(ps.include?("errcode_ret")) then
          ocl_icd_loader_gen_source += "    if( errcode_ret != NULL ) {\n";
          ocl_icd_loader_gen_source += "      *errcode_ret = #{$cl_data_type_error[fps[0]]};\n"
          ocl_icd_loader_gen_source += "    }\n"
          if return_type != "void" then
            ocl_icd_loader_gen_source += "    RETURN(NULL);\n"
          else
            ocl_icd_loader_gen_source += "    return;\n"
          end
        elsif ($non_standard_error.include?(func_name)) then
          if return_type != "void" then
            ocl_icd_loader_gen_source += "    RETURN(NULL);\n"
          else
            ocl_icd_loader_gen_source += "    return;\n"
          end
        else
          if return_type != "void" then
            ocl_icd_loader_gen_source += "    RETURN(#{$cl_data_type_error[fps[0]]});\n" if return_type != "void"
          else
            ocl_icd_loader_gen_source += "    return;\n"
          end
        end
      }

      if(fps[0] == "cl_platform_id") then
        ocl_icd_loader_gen_source += "  #{fps[1]}=selectPlatformID(#{fps[1]});\n"
      end
      ocl_icd_loader_gen_source += "  if( (struct _#{fps[0]} *)#{fps[1]} == NULL) {\n"
      error_handler.call
      ocl_icd_loader_gen_source += "  }\n"
      if return_type != "void" then
        return_debug="RETURN"
      else
        return_debug="return"
      end
      ocl_icd_loader_gen_source += "  #{return_debug}(KHR_ICD2_DISPATCH((struct _#{fps[0]} *)#{fps[1]})->#{func_name}("
      ocl_icd_loader_gen_source += ps.join(", ")
      ocl_icd_loader_gen_source += "));\n"
      ocl_icd_loader_gen_source += "}\n\n"
    }
    $api_entries.each &(api_stub)
    $api_entries.each &(api_proc.curry[true])
    $api_entries.each &(api_proc.curry[false])
    ocl_icd_loader_gen_source += "#pragma GCC visibility push(hidden)\n\n"
    skip_funcs = $specific_loader_funcs
    $api_entries.each { |func_name, entry|
      #next if func_name.match(/EXT$/)
      #next if func_name.match(/KHR$/)
      if (skip_funcs.include?(func_name)) then
        ocl_icd_loader_gen_source += <<EOF
#if defined(__APPLE__) || defined(__MACOSX)
#define #{func_name}_hid #{func_name}
#else
extern typeof(#{func_name}) #{func_name}_hid;
#endif
extern typeof(#{func_name}) #{func_name}_disp;
EOF
      else
        ocl_icd_loader_gen_source += <<EOF
#if defined(__APPLE__) || defined(__MACOSX)
#define #{func_name}_hid #{func_name}
#else
hidden_alias(#{func_name});
#endif
EOF
      end
    }
    ocl_icd_loader_gen_source += "\n\nstruct func_desc const function_description[]= {\n"
    $api_entries.each { |func_name, entry|
      #next if func_name.match(/EXT$/)
      #next if func_name.match(/KHR$/)
      ocl_icd_loader_gen_source << "  {\"#{func_name}\", (void(* const)(void))&#{func_name}_hid },\n"
    }
    ocl_icd_loader_gen_source << <<EOF
  {NULL, NULL}
};

EOF
    ocl_icd_loader_gen_source << "struct _cl_icd_dispatch master_dispatch = {\n"
    ($api_entries.length+$buff-1).times { |i|
      if( $known_entries[i] ) then
        ocl_icd_loader_gen_source << "  #{$known_entries[i]}_disp,\n"
      else
        ocl_icd_loader_gen_source << "  (void *) NULL,\n"
      end
    }
    if( $known_entries[$api_entries.length+$buff-1] ) then
      ocl_icd_loader_gen_source << "  #{$known_entries[$api_entries.length+$buff-1]}\n"
    else
      ocl_icd_loader_gen_source << "  (void *) NULL\n"
    end
    ocl_icd_loader_gen_source << "};\n"

    ocl_icd_loader_gen_source << "struct _cl_icd_dispatch deinit_dispatch = {\n"
    ($api_entries.length+$buff-1).times { |i|
      if( $known_entries[i] ) then
        ocl_icd_loader_gen_source << "  #{$known_entries[i]}_unsupp,\n"
      else
        ocl_icd_loader_gen_source << "  (void *) NULL,\n"
      end
    }
    if( $known_entries[$api_entries.length+$buff-1] ) then
      ocl_icd_loader_gen_source << "  #{$known_entries[$api_entries.length+$buff-1]}\n"
    else
      ocl_icd_loader_gen_source << "  (void *) NULL\n"
    end
    ocl_icd_loader_gen_source << "};\n"

    ocl_icd_loader_gen_source << <<EOF

#ifdef DEBUG_OCL_ICD
void dump_platform(clGEFA_t f, cl_platform_id pid) {
  debug(D_ALWAYS, "platform @%p:  name=field_in_struct [clGetExtensionFunctionAddress(name)/clGetExtensionFunctionAddressForPlatform(name)]", pid);
EOF
    $api_entries_array.each { |entry|
      e = entry.gsub("\r"," ").gsub("\n"," ").gsub("\t"," ").
        sub(/.*CL_API_CALL *([^ ()]*)[ ()].*$/m, '\1')
      ocl_icd_loader_gen_source << "  dump_field(pid, f, #{e});\n"
    }

    ocl_icd_loader_gen_source << <<EOF
}
#endif

void _populate_dispatch_table(
    cl_platform_id pid,
    clIcdGetFunctionAddressForPlatformKHR_fn pltfn_fn_ptr,
    struct _cl_icd_dispatch *dispatch) {
EOF
    ($api_entries.length+$buff).times { |i|
      if ( e = $known_entries[i] ) then
        ocl_icd_loader_gen_source << <<EOF
  dispatch->#{e} = (typeof(#{e})*)pltfn_fn_ptr(pid, "#{e}");
  if (!dispatch->#{e})
    dispatch->#{e} = #{e}_unsupp;
EOF
      else
        ocl_icd_loader_gen_source << "  dispatch->clUnknown#{i} = NULL;\n"
      end
    }

    ocl_icd_loader_gen_source << <<EOF
}

#pragma GCC visibility pop

EOF
    return ocl_icd_loader_gen_source;
  end

  def self.generate_from_database(yamlfile)
    load_database(yamlfile)
    File.open('ocl_icd.h','w') { |f|
      f.puts generate_ocl_icd_header
    }
    File.open('ocl_icd_loader_gen.h','w') { |f|
      f.puts generate_ocl_icd_loader_header
    }
    File.open('ocl_icd_loader_gen.map','w') { |f|
      f.puts generate_ocl_icd_loader_map
    }
    File.open('ocl_icd_bindings.c','w') { |f|
      f.puts generate_ocl_icd_bindings_source
    }
    File.open('ocl_icd_loader_gen.c','w') { |f|
      f.puts generate_ocl_icd_loader_gen_source
    }
    File.open('dummy_icd_layer_gen.c','w') { |f|
      f.puts generate_icd_layer_source
    }
  end

  ##########################################################
  ##########################################################
  # rust-database mode
  # Flatten the interface database to a line-per-slot table for the Rust
  # loader's build.rs:  <slot>\t<name>\t<prototype with \n escapes>\n.
  # The name is the CL_API_CALL identifier (empty when the slot holds no
  # declaration, i.e. the nil slots of the historical numbering); the
  # prototype is the verbatim YAML block scalar. Ruby owns YAML parsing
  # everywhere in this project; the consumer needs neither.
  def self.generate_rust_table(yamlfile)
    doc = YAML::load_file(yamlfile)
    File.open('ocl_interface.table','w') { |f|
      doc.keys.sort.each { |k|
        v = doc[k].to_s
        name = (v.match(/CL_API_CALL\s*([A-Za-z0-9_]+)\s*\(/m) || [nil,''])[1]
        f.puts "#{k}\t#{name}\t#{v.gsub(/\n/, '\\n')}"
      }
    }
  end


  ##########################################################
  ##########################################################
  # rust-map mode
  # Linker version script for the Rust loader, derived from the C loader's
  # generated map: same symbol -> OPENCL_x.y node assignment (the ABI
  # contract), minus symbols the Rust build does not export. Port of
  # rust/scripts/gen_map.py. Usage: --mode rust-map --c-map M --cdylib S
  # --out O.
  def self.generate_rust_map(cmap, so, out)
    src = File.read(cmap).gsub(%r{/\*[\s\S]*?\*/}, '')
    blocks = src.scan(/(OPENCL_[\d.]+)\s*\{([\s\S]*?)\}\s*(?:OPENCL_[\d.]+)?\s*;/)
    defined = {}
    ok = IO.popen(['nm', '-D', '--defined-only', so]) { |io| io.read }
    raise 'nm failed' unless $?.success?
    ok.split("\n").each { |line|
      parts = line.split
      defined[parts[-1].split('@')[0]] = true if parts.length >= 3
    }
    nodes = []
    prev = nil
    blocks.each { |name, body|
      syms = body.scan(/(cl\w+)\s*;/).flatten.uniq.select { |s| defined.key?(s) }.sort
      next if syms.empty?
      tail = prev ? "} #{prev};" : "  local:\n    *;\n};"
      nodes << "#{name} {\n  global:\n" + syms.map { |s| "    #{s};\n" }.join + tail
      prev = name
    }
    File.write(out, nodes.join("\n\n") + "\n")
    total = nodes.sum { |b| b.count(';') }
    warn format('%d symbols in %d version nodes', total, nodes.length)
  end

  ##########################################################
  ##########################################################
  # rust-archive mode
  # Static convenience archive of the crate's objects for libtool, harvested
  # through a capturing pseudo-linker. Port of rust/scripts/archive-objects.py
  # (same fail-loud guards). Usage: --mode rust-archive [--cargo C]
  # [--manifest-dir D] --out A.
  def self.archive_rust_objects(cargo, manifest_dir, out)
    require 'tmpdir'
    manifest_dir = File.expand_path(manifest_dir)
    tag = "#{$$}-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
    argv_file = File.join(Dir.tmpdir, "ocl-icd-rs-link-argv-#{tag}")
    rsp_file  = File.join(Dir.tmpdir, "ocl-icd-rs-link-rsp-#{tag}")
    wrapper   = File.join(Dir.tmpdir, "ocl-icd-rs-link-#{tag}")
    File.write(wrapper, format(
      "#!/bin/bash\nfor a in \"$@\"; do\n  [ \"$a\" = \"-shared\" ] || continue\n  printf \"%%s\\n\" \"$@\" > %s\n  for b in \"$@\"; do\n    case \"$b\" in @*) [ -e \"$${b#@}\" ] && cp \"$${b#@}\" %s ;; esac\n  done\n  exit 1\ndone\nexec \"${CC:-cc}\" \"$@\"\n",
      argv_file, rsp_file))
    File.chmod(0o755, wrapper)
    old_rustflags = ENV['RUSTFLAGS']
    ENV['RUSTFLAGS'] = ((old_rustflags || '') + ' -C linker=' + wrapper).strip
    log = ''
    Dir.chdir(manifest_dir) do
      log = IO.popen([cargo, 'build', '--release'], err: [:child, :out], &:read) || ''
    end
  ensure
    ENV['RUSTFLAGS'] = old_rustflags
    abort "linker wrapper never invoked for a -shared link:\n#{log[-500..]}\n" unless File.exist?(argv_file)
    args = []
    File.foreach(argv_file) { |l|
      a = l.chomp
      if a.start_with?('@')
        src = a[1..]
        src = File.exist?(src) ? src : (File.exist?(rsp_file) ? rsp_file : nil)
        File.foreach(src) { |x| args << x.strip unless x.strip.empty? } if src
        next
      end
      args << a
    }
    keep = lambda { |a|
      b = File.basename(a)
      return false if b.include?('build_script')
      return false if a =~ /rustc[A-Za-z0-9]+\/symbols\.o$/
      return false if b == 'symbols.o' && !a.include?('/out/')
      true
    }
    plain = args.select { |a| a.end_with?('.o') && keep.call(a) }
    libs  = args.select { |a| (a.end_with?('.rlib') || a.end_with?('.a')) && keep.call(a) }
    unless plain.any? { |a| File.basename(a).include?('ocl_icd_rs') }
      abort format('no crate codegen objects among %d harvested inputs (+%d rlibs) — refusing to write an archive that would export nothing. argv tokens: %p', plain.length, libs.length, args[0, 12])
    end
    final = plain.dup
    Dir::mktmpdir('ocl-icd-rs-obj-') { |tmp|
      libs.each_with_index { |o, i|
        d = File.join(tmp, "m#{i}")
        Dir.mkdir(d)
        Dir.chdir(d) { system('ar', 'x', o, out: File::NULL, err: File::NULL) or abort "ar x #{o} failed" }
        Dir.children(d).select { |x| x.end_with?('.o') }.sort.each { |x| final << File.join(d, x) }
      }
      File.unlink(out) if File.exist?(out)
      system('ar', 'qc', out, *final) or abort 'ar qc failed'
    }
    system('ranlib', out) or abort 'ranlib failed'
    warn format('archived %d objects (%d crate + %d from %d rlibs) -> %s', final.length, plain.length, final.length - plain.length, libs.length, out)
  end

  ##########################################################
  ##########################################################
  # rust-generate mode
  # Rust counterpart of the entry-point subset of generate_from_database:
  # emits rust/src/slots.rs and rust/src/gen_forwarders.rs straight from the
  # interface database (one interpreter, one generator, zero crate deps).
  # Ported line-by-line from the python generator that this mode supersedes;
  # the independent parity oracle.

  RS_SPECIFIC_LOADER = %w[
    clGetExtensionFunctionAddress clGetPlatformIDs clGetGLContextInfoKHR
    clUnloadCompiler clUnloadPlatformCompiler clCreateContext
    clCreateContextFromType clWaitForEvents clGetPlatformInfo].to_set
  # name -> loader-disp implementation: <name>_disp for every name in the
  # array above (clGetExtensionFunctionAddress_disp is still looked up here
  # for the slot-65 row of gen_slot_disp, although the function is not a
  # SPECIFIC_LOADER skip case).
  RS_LOADER_DISP_NAMES = RS_SPECIFIC_LOADER.to_a.to_h { |n| [n, n + "_disp"] }
  RS_FIRST_TYPE_ERROR = {
    'cl_platform_id' => ['CL_INVALID_PLATFORM', 'platform'],
    'cl_device_id' => ['CL_INVALID_DEVICE', 'object'],
    'cl_context' => ['CL_INVALID_CONTEXT', 'object'],
    'cl_command_queue' => ['CL_INVALID_COMMAND_QUEUE', 'object'],
    'cl_mem' => ['CL_INVALID_MEM_OBJECT', 'object'],
    'cl_program' => ['CL_INVALID_PROGRAM', 'object'],
    'cl_kernel' => ['CL_INVALID_KERNEL', 'object'],
    'cl_event' => ['CL_INVALID_EVENT', 'object'],
    'cl_sampler' => ['CL_INVALID_SAMPLER', 'object'],
  }
  RS_NON_STANDARD_ERROR = Set.new(%w[clGetExtensionFunctionAddressForPlatform clSVMAlloc])
  RS_OBJECT_TYPES = RS_FIRST_TYPE_ERROR.keys.to_set
  # Khronos base type -> Rust type. Types mapping to themselves
  # (cl_int, cl_uint, cl_bool, the object handles, the _info enums,
  # cl_device_type, cl_context_properties) are the DEFAULT -- see
  # rs_base_to_rust -- so only divergences are listed.
  RS_TYPE_DIVERGENCES = {
    'size_t' => 'usize', 'char' => 'c_char', 'void' => 'c_void',
    'cl_char' => 'i8', 'cl_uchar' => 'u8', 'cl_short' => 'i16', 'cl_ushort' => 'u16',
    'cl_long' => 'i64', 'cl_flags' => 'u64', 'cl_bitfield' => 'u64', 'cl_ulong' => 'u64',
    'cl_mem_flags' => 'u64', 'cl_map_flags' => 'u64', 'cl_svm_mem_flags' => 'u64',
    'cl_mem_migration_flags' => 'u64', 'cl_command_queue_properties' => 'u64',
    'cl_device_fp_config' => 'u64',
    'cl_device_partition_property' => 'isize', 'cl_sampler_properties' => 'isize',
    'cl_pipe_properties' => 'isize', 'cl_kernel_execution_properties' => 'isize',
    'cl_command_queue_info' => 'u32', 'cl_mem_object_type' => 'u32', 'cl_image_info' => 'u32',
    'cl_build_status' => 'i32', 'cl_program_info' => 'u32', 'cl_program_binary_type' => 'u32',
    'cl_program_build_info' => 'u32', 'cl_kernel_info' => 'u32', 'cl_kernel_work_group_info' => 'u32',
    'cl_kernel_arg_info' => 'u32', 'cl_event_info' => 'u32', 'cl_event_status' => 'i32',
    'cl_profiling_info' => 'u32', 'cl_sampler_info' => 'u32', 'cl_addressing_mode' => 'u32',
    'cl_filter_mode' => 'u32', 'cl_channel_order' => 'u32', 'cl_channel_type' => 'u32',
    'cl_gl_info_type' => 'u32', 'cl_gl_texture_info' => 'u32', 'cl_gl_platform_info' => 'u32',
    'cl_gl_context_info' => 'u32', 'cl_image_desc' => 'c_void', 'cl_image_format' => 'c_void',
    'cl_layer_info' => 'u32', 'cl_layer_properties' => 'usize',
    'cl_GLuint' => 'u32', 'cl_GLint' => 'i32', 'cl_GLenum' => 'u32', 'cl_GLsizei' => 'u32',
    'clGLenum' => 'u32', 'clGLint' => 'i32', 'clGLsizei' => 'u32',
  }

  # Khronos types that ARE their own Rust type name (typedefs in types.rs).
  RS_TYPE_IDENTITY = Set.new(%w[
    cl_int cl_uint cl_bool cl_device_type cl_context_properties
    cl_platform_info cl_device_info cl_context_info
    cl_platform_id cl_device_id cl_context cl_command_queue
    cl_mem cl_program cl_kernel cl_event cl_sampler])

  def self.rs_base_to_rust(bt)
    RS_TYPE_DIVERGENCES.fetch(bt) { RS_TYPE_IDENTITY.include?(bt) ? bt : 'cl_int' }
  end

  def self.rs_ident_ok?(x)
    !!(x =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/)
  end

  def self.rs_parse_entry(entry)
    # parameter NAMES live inside /* */ -> replace each comment by its name
    body = entry.gsub(%r{/\*.*?\*/}m) { |m0|
      inner = m0[2..-3].gsub(/\A[\s*]+|[\s*]+\z/, '')
      w = inner.split
      ok = !w.empty? && w.all? { |x| rs_ident_ok?(x) }
      ok ? w[-1] : 'unnamed'
    }
    m = body.match(/CL_API_CALL\s*([A-Za-z0-9_]+)\s*\(/m)
    return nil unless m
    name = m[1]
    ret_m = body.match(/CL_API_ENTRY\s+(.*?)\s*CL_API_CALL/m)
    ret_raw = ret_m ? ret_m[1].split.join(' ') : 'cl_int'
    ret_raw = ret_raw[6..-1] if ret_raw.start_with?('const ')
    if ret_raw == 'void'
      ret_base = 'void'
    else
      toks0 = ret_raw.gsub('*', ' ').gsub('[', ' ').split
      ret_base = toks0.empty? ? '' : toks0[-1]
    end
    ret_ptr = ret_raw != 'void' && (ret_raw.include?('*') || ret_raw.include?('[') || RS_OBJECT_TYPES.include?(ret_base))
    ret_u64 = !ret_ptr && ret_base == 'cl_ulong'
    ret_void = !ret_ptr && !ret_u64 && ret_raw == 'void'
    start = body.index('(', m.end(0) - 1)
    depth = 0
    fin = nil
    (start...body.length).each { |i|
      ch = body[i]
      if ch == '('
        depth += 1
      elsif ch == ')'
        depth -= 1
        if depth == 0
          fin = i
          break
        end
      end
    }
    return nil unless fin
    flat = body[(start + 1)...fin].split.join(' ')
    chunks = []
    cur = ''
    depth = 0
    flat.each_char { |ch|
      if ch == '('
        depth += 1
      elsif ch == ')'
        depth -= 1
      end
      if ch == ',' && depth == 0
        chunks << cur
        cur = ''
      else
        cur += ch
      end
    }
    chunks << cur unless cur.strip.empty?
    params = []
    chunks.each { |c0|
      c = c0.strip
      next if c.empty? || c == 'void'
      # callback parameter: "* name)" / "* /* name */)" with an unclosed '('
      fmc = c.match(/\*\s*(?:\/\*\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\*\/\s*)?\)/)
      if fmc
        pre = c[0...fmc.begin(0)]
        if pre.count('(') - pre.count(')') >= 1
          params << ['*mut c_void', fmc[1]]
          next
        end
      end
      nm = c.match(/([A-Za-z_][A-Za-z0-9_]*)\s*\z/)
      return nil unless nm
      pname = nm[1]
      decl = c[0...nm.begin(1)]
      stars = decl.count('*')
      toks0 = decl.gsub('*', ' ').split
      bt = toks0.empty? ? 'void' : toks0[-1]
      toks = toks0.reject { |t| t == 'const' }
      rust = RS_TYPE_DIVERGENCES.key?(bt) ? RS_TYPE_DIVERGENCES[bt] : (RS_TYPE_IDENTITY.include?(bt) ? bt : (stars > 0 ? 'c_void' : 'usize'))
      before = decl.split(bt, 2)[0].to_s
      is_const = toks.include?('const') || before.split.include?('const')
      stars.times { rust = '*mut ' + rust }
      rust = rust.sub('*mut', '*const') if is_const && rust.start_with?('*mut')
      params << [rust, pname]
    }
    if ret_ptr
      ret_rust = '*mut c_void'
    elsif ret_u64
      ret_rust = 'u64'
    elsif ret_base == 'void'
      ret_rust = '()'
    else
      ret_rust = RS_TYPE_DIVERGENCES.key?(ret_base) ? RS_TYPE_DIVERGENCES[ret_base] : (RS_TYPE_IDENTITY.include?(ret_base) ? ret_base : 'cl_int')
    end
    params = params.map { |pt, pn| pn == 'errcode_ret' ? ['*mut cl_int', pn] : [pt, pn] }
    seen = {}
    uniq = []
    params.each { |pt, pn|
      if seen.key?(pn)
        seen[pn] += 1
        pn = format('%s%d', pn, seen[pn])
      else
        seen[pn] = 0
      end
      uniq << [pt, pn]
    }
    params = uniq
    [name, ret_rust, ret_ptr, ret_void, ret_u64, params]
  end

  def self.rs_classify(t)
    ts = t.strip
    return 'Ptr' if ts.start_with?('*') || RS_FIRST_TYPE_ERROR.key?(ts)
    return 'U64' if ts == 'u64' || ts == 'cl_device_type'
    'Trivial'
  end

  def self.rs_marsh_of(pt, pn)
    rs_classify(pt) == 'U64' ? format('val(&%s)', pn) : format('%s as usize', pn)
  end

  def self.generate_rust_bindings(yamlfile, slots_out, fwders_out)
    d = YAML.load_file(yamlfile)
    n = d.keys.map(&:to_i).max + 1
    snames = (0...n).map { |i|
      v = d[i]
      mm = v && v.match(/CL_API_CALL\s+([A-Za-z0-9_]+)\s*\(/m)
      mm ? mm[1] : ''
    }
    slines = ['// GENERATED by icd_generator.rb --mode rust-generate -- do not edit',
              format('pub const NUM_DISPATCH_SLOTS: usize = %d;', n),
              'pub const DISPATCH_SLOT_NAMES: [&str; NUM_DISPATCH_SLOTS] = [']
    snames.each { |nm| slines << format('    "%s",', nm) }
    slines << '];'
    slines << ''
    File.write(slots_out, slines.join("\n"))

    entries = {}
    slot_of = {}
    (0...n).each { |i|
      v = d[i]
      next if v.nil? || v.to_s.strip.empty?
      p = rs_parse_entry(v)
      if p.nil?
        warn format('// UNPARSED slot %d', i)
        next
      end
      nm = p[0]
      next if entries.key?(nm)
      entries[nm] = [i] + p[1..]
      slot_of[nm] = i
    }

    out = [
      '// GENERATED by icd_generator.rb --mode rust-generate from ocl_interface.yaml',
      '// -- do not edit. Port of icd_generator.rb to Rust; oracle in rust/scripts.',
      '#![allow(clippy::too_many_arguments, unused_variables, non_snake_case, dead_code)]',
      'use crate::dispatch::object_dispatch;',
      'use crate::exports::{call_by_slot, call_by_slot_void, platform_dispatch_table, val, default_platform_id};',
      'use crate::exports::{clGetPlatformIDs_disp, clGetPlatformInfo_disp, clCreateContext_disp,',
      '    clCreateContextFromType_disp, clWaitForEvents_disp, clGetGLContextInfoKHR_disp,',
      '    clGetExtensionFunctionAddress_disp,',
      '    clUnloadCompiler_disp, clUnloadPlatformCompiler_disp};',
      'use crate::gen_entry;',
      'use crate::types::*;',
      'use core::ffi::{c_char, c_void};',
      '',
      '// error constants for NULL-object paths (khronos values)',
      'const CL_INVALID_CONTEXT: cl_int = -34;',
      'const CL_INVALID_COMMAND_QUEUE: cl_int = -36;',
      'const CL_INVALID_MEM_OBJECT: cl_int = -38;',
      'const CL_INVALID_EVENT: cl_int = -40;',
      'const CL_INVALID_KERNEL: cl_int = -42;',
      'const CL_INVALID_SAMPLER: cl_int = -35;',
      'const CL_INVALID_PROGRAM: cl_int = -44;',
      'const CL_INVALID_OPERATION: cl_int = -59;',
      '',
    ]

    skipped = []
    generated = []
    names_by_slot = entries.keys.sort_by { |k| entries[k][0] }
    names_by_slot.each { |name|
      slot, ret_rust, ret_ptr, ret_void, ret_u64, params = entries[name]
      next if RS_SPECIFIC_LOADER.include?(name)
      if params.empty?
        skipped << [name, 'no params']
        next
      end
      ft = params[0][0]
      base = ft.dup
      base = base[5..-1] while base.start_with?('*mut ') || base.start_with?('*const ')
      fte = RS_FIRST_TYPE_ERROR[base]
      if fte.nil?
        skipped << [name, 'unmapped first param ' + ft]
        next
      end
      err_const, route = fte
      has_err = params.any? { |_t, pn| pn == 'errcode_ret' }
      nonstd = RS_NON_STANDARD_ERROR.include?(name)
      p0 = params[0][1]
      arglist = params.map { |pt, pn| format('%s: %s', pn, pt) }.join(', ')
      marsh = params.map { |pt, pn| rs_marsh_of(pt, pn) }.join(', ')

      nb = []
      if has_err
        nb << format('if !errcode_ret.is_null() { *errcode_ret = %s; }', err_const)
        nb << (ret_ptr ? 'return core::ptr::null_mut();' :
               (!ret_void && !ret_u64 ? format('return %s;', err_const) : 'return;'))
      elsif nonstd
        nb << 'return core::ptr::null_mut();'
      else
        nb << (ret_ptr ? 'return core::ptr::null_mut();' :
               (ret_void ? 'return;' : format('return %s;', err_const)))
      end

      out << format('// ── slot %d: %s ──', slot, name)
      out << '#[allow(clippy::too_many_arguments)]'
      out << format('pub unsafe extern "C" fn %s_disp(%s) -> %s {', name, arglist, ret_rust)
      if name == 'clGetExtensionFunctionAddressForPlatform'
        out << '    if !func_name.is_null() {'
        out << '        let cname = unsafe { std::ffi::CStr::from_ptr(func_name) };'
        out << '        if let Ok(s) = cname.to_str() {'
        out << '            if s.len() > 3 && (s.ends_with("KHR") || s.ends_with("EXT")) {'
        out << '                if let Some(a) = crate::gen::func_desc_lookup(s) { return a; }'
        out << '            }'
        out << '        }'
        out << '    }'
      end
      if route == 'platform'
        if ret_void
          ret_none = 'return'
        elsif ret_ptr || ret_u64
          ret_none = 'return core::ptr::null_mut()'
        else
          ret_none = format('return %s', err_const)
        end
        joined = nb.length == 1 ? nb[0] : nb.join(' ') + ' ' + ret_none
        out << format("    let %1$s = if %1$s.is_null() {        match default_platform_id() {\n            Some(p) => p,\n            None => { %3$s }\n        }\n    } else { %1$s };",
                      p0, '', joined)
        out << format('    let t = match platform_dispatch_table(%s) {', p0)
        out << '        Some(t) => t,'
        out << '        None => {'
        nb.each { |l| out << '        ' + l }
        out << '        }'
        out << '    };'
      else
        out << format('    if %s.is_null() {', p0)
        nb.each { |l| out << '    ' + l }
        out << '    }'
        out << format('    let t = object_dispatch(%s);', p0)
      end
      slot_expr = format('crate::dispatch::slot_of("%s")', name)
      if ret_ptr
        out << format('    call_by_slot(t, %s, &[%s]) as *mut c_void', slot_expr, marsh)
      elsif ret_u64
        out << format('    call_by_slot(t, %s, &[%s]) as u64', slot_expr, marsh)
      elsif ret_void
        out << format('    call_by_slot_void(t, %s, &[%s]);', slot_expr, marsh)
      else
        out << format('    call_by_slot(t, %s, &[%s]) as cl_int', slot_expr, marsh)
      end
      out << '}'
      npad = [0, 10 - params.length].max
      pads = (0...npad).map { |k| format('__pad%d', k) }.join(',')
      out << format('gen_entry!(%1$s, crate::dispatch::slot_of("%1$s"), %2$s, (%3$s), [%4$s], %1$s_disp);',
                    name, ret_rust, arglist, pads)
      out << ''
      generated << name
    }

    exported = (generated + (RS_SPECIFIC_LOADER.to_a - ['clGetExtensionFunctionAddress']) +
                ['clGetExtensionFunctionAddressForPlatform', 'clDeinitCompound', 'clIcdGetPlatformIDsKHR'])
    exported = exported.uniq.sort - ['clGetICDLoaderInfoOCLICD']
    out << '/// Name -> loader export address (C: function_description[] table).'
    use_list = ((RS_SPECIFIC_LOADER.to_a - ['clGetExtensionFunctionAddress']) +
                ['clDeinitCompound', 'clIcdGetPlatformIDsKHR']).uniq.sort
    out << 'use crate::exports::{' + use_list.join(', ') + '};'
    out << 'pub fn func_desc_lookup(name: &str) -> Option<*mut c_void> {'
    out << '    match name {'
    exported.each { |fn_name|
      out << format('        "%1$s" => Some(%1$s as *mut c_void),', fn_name)
    }
    out << '        _ => None,'
    out << '    }'
    out << '}'
    out << ''

    out << "/// Address of the loader's layer-facing (`_disp`) implementation of slot `slot`."
    out << 'pub fn gen_slot_disp(slot: usize) -> *mut c_void {'
    out << '    match slot {'
    seen_slots = Set.new
    names_by_slot.each { |name|
      slot = slot_of[name]
      if RS_SPECIFIC_LOADER.include?(name)
        ln = RS_LOADER_DISP_NAMES[name]
        if ln
          seen_slots << slot
          out << format('        %d => %s as *mut c_void,', slot, ln)
        end
        next
      end
      next if seen_slots.include?(slot) || !generated.include?(name)
      seen_slots << slot
      out << format('        %d => %s_disp as *mut c_void,', slot, name)
    }
    out << '        _ => core::ptr::null_mut(),'
    out << '    }'
    out << '}'
    out << ''

    out << '/// Address of the post-deinit (`_unsupp`) variant of slot `slot`:'
    out << '/// sets errcode_ret = CL_INVALID_OPERATION when the signature carries one.'
    out << 'pub fn gen_slot_unsupp(slot: usize) -> *mut c_void {'
    out << '    match slot {'
    seen_slots = Set.new
    stub_defs = []
    stub_names = Set.new
    names_by_slot.each { |name|
      slot = slot_of[name]
      next if RS_SPECIFIC_LOADER.include?(name) || seen_slots.include?(slot)
      seen_slots << slot
      _s, ret_rust, ret_ptr, ret_void, ret_u64, params = entries[name]
      eidx = params.index { |_t, pn| pn == 'errcode_ret' }
      eidx = nil if eidx && eidx >= 10
      if eidx
        fn_name = format('us_err_s%d_a%d', slot, eidx)
        out << format('        %d => %s as *mut c_void,', slot, fn_name)
        unless stub_names.include?(fn_name)
          stub_names << fn_name
          stub_defs << format("extern \"C\" fn %s(a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize) -> usize {\n    unsafe {\n        let __a = [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9];\n        if __a[%d] != 0 { *(__a[%d] as *mut cl_int) = CL_INVALID_OPERATION; }\n    }\n    0\n}",
            fn_name, eidx, eidx)
        end
      elsif ret_ptr || RS_NON_STANDARD_ERROR.include?(name)
        out << format('        %d => unsupp_null as *mut c_void,', slot)
      elsif ret_void
        out << format('        %d => unsupp_void as *mut c_void,', slot)
      else
        out << format('        %d => unsupp_int as *mut c_void,', slot)
      end
    }
    out << '        1 => unsupp_int as *mut c_void, // clGetPlatformInfo (no errcode_ret param: plain -59)'
    out << '        65 => unsupp_null as *mut c_void, // clGetExtensionFunctionAddress'
    out << '        _ => core::ptr::null_mut(),'
    out << '    }'
    out << '}'
    out.concat(stub_defs)
    out << <<'RUBY'

extern "C" fn unsupp_int(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) -> cl_int {
    CL_INVALID_OPERATION
}
extern "C" fn unsupp_null(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) -> usize {
    0
}
extern "C" fn unsupp_void(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) {}
extern "C" fn unsupp_errcode(_a0: usize, _a1: usize, _a2: usize, _a3: usize, _a4: usize, a5: usize) -> usize {
    unsafe {
        if a5 != 0 {
            *(a5 as *mut cl_int) = CL_INVALID_OPERATION;
        }
    }
    0
}
RUBY
    skipped.each { |name, why| out << format('// SKIPPED %s: %s', name, why) }
    File.write(fwders_out, out.join("\n") + "\n")
    ng = generated.length
    printf("generated: %d functions; skipped: %d\n", ng, skipped.length)
  end

  ##########################################################
  ##########################################################
  # update-database mode
  def self.savedb(yamlfile)
    File::open(yamlfile,"w") { |f|
      f.write($license.gsub(/^/,"# "))
      f.write( <<EOF

# In Intel (OpenCL 1.1):
# * clSetCommandQueueProperty(13): nil (deprecated in 1.1)
# * clGetGLContextInfoKHR(74): function present with its symbol
# * 75-80: nil
# * 92: correspond to symbol clGetKernelArgInfo (first abandonned version?)
# * 93-: garbage
# In nvidia (OpenCL 1.1):
# * clGetGLContextInfoKHR(74): function present but no symbol
# * 75-80: nil
# * 89-: nil
# * only two OpenCL symbols: clGetPlatformInfo(1) and clGetExtensionFunctionAddress(65)
# In AMD (OpenCL 1.2):
# * clGetPlatformIDs(0): nil (symbol present)
# * clGetGLContextInfoKHR(74): function present but no symbol
# * 75-80: nil
# * 92: nil
# * 109-118: nil
# * 119-: garbage

EOF
)
      # Not using YAML::dump as:
      # * keys are not ordered
      # * strings are badly formatted in new YAML ruby implementation (psych)
      # * it is very easy to do it ourself
      #f.write(YAML::dump(api_db))
      f.write("--- ")
      $known_entries.keys.sort.each { |k|
        f.write("\n#{k}: |-\n  ")
        f.write($api_entries[$known_entries[k]].gsub("\n","\n  "))
      }
      f.write("\n")
    }
  end

  def self.updatedb_from_input(dbfile, inputfile)
    parse_headers
    load_database(dbfile, with_windows=true)
    doc = YAML::load_file(inputfile)
    doc.delete(-1)
    doc.each_key {|i|
      next if $known_entries[i]
      $known_entries[i]=doc[i]
    }
    self.savedb(dbfile)
  end

end

############################################################
############################################################
############################################################

### Main program

require 'optparse'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: cd_generator.rb [options] mode"

  opts.on("-d", "--database FILE", String, "YAML file (default ocl_interface.yaml)") do |v|
    options[:database] = v
  end
  opts.on("-i", "--input FILE", String,
          "binding between OpenCL functions and entry number (required for update-database)") \
  do |v|
    options[:input] = v
  end
  opts.on("-s", "--[no-]system-headers",
          "Look for OpenCL functions in system header files") \
  do |v|
    options[:"system-headers"] = v
  end
  opts.on("--c-map FILE", String, "C version map input (rust-map)") { |v| options[:"c-map"] = v }
  opts.on("--cdylib FILE", String, "cdylib to inspect for defined symbols (rust-map)") { |v| options[:"cdylib"] = v }
  opts.on("--manifest-dir DIR", String, "cargo manifest directory (rust-archive)") { |v| options[:"manifest-dir"] = v }
  opts.on("--out FILE", String, "output path (rust-map / rust-archive)") { |v| options[:out] = v }
  opts.on("--cargo CMD", String, "cargo command (rust-archive)") { |v| options[:cargo] = v }
  opts.on("--rust-slots FILE", String, "slots.rs output path (rust-generate)") do |v|
    options[:"rust-slots"] = v
  end
  opts.on("--rust-gen FILE", String, "gen_forwarders.rs output path (rust-generate)") do |v|
    options[:"rust-gen"] = v
  end
  opts.on("-m", "--mode [MODE]", [:database, :generate, :"update-database", :"rust-generate", :"rust-map", :"rust-archive"],
          "Select mode (database, generate, update-database, rust-generate, rust-map, rust-archive)") do |m|
    options[:mode] = m
  end
end.parse!

if !options[:database] then
  options[:database] = "ocl_interface.yaml"
end

if !options[:mode] then
  raise "--mode option required"
end
if options[:mode] == :generate then
  if !options[:"system-headers"] then
    IcdGenerator.generate_sources(from_headers=false, from_database=true, database=options[:database])
  else
    IcdGenerator.generate_sources(from_headers=true, from_database=false)
  end
elsif options[:mode] == :"rust-map" then
  IcdGenerator.generate_rust_map(options[:"c-map"], options[:cdylib], options[:out])
elsif options[:mode] == :"rust-archive" then
  IcdGenerator.archive_rust_objects(options[:cargo] || "cargo",
    options[:"manifest-dir"] || ".", options[:out] || "libocl-icd-rs.a")
elsif options[:mode] == :"rust-generate" then
  IcdGenerator.generate_rust_bindings(options[:database],
    options[:"rust-slots"] || "rust/src/slots.rs",
    options[:"rust-gen"] || "rust/src/gen_forwarders.rs")
elsif options[:mode] == :"update-database" then
  if !options[:input] then
    raise "--input option required"
  end
  IcdGenerator.updatedb_from_input(options[:database], options[:input])
elsif options[:mode] == :database then
  IcdGenerator.generate_from_database(options[:database])
else
  raise "Mode must be one of generate, database or update-database not #{options[:mode]}"
end

