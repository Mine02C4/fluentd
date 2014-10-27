# coding: utf-8
require 'rexml/document'
require 'time'
require 'tracer'

module Fluent
  class WindowsEventInput < Input
    Plugin.register_input('windows_event', self)

    EvtQueryChannelPath          = 0x1
    EvtQueryFilePath             = 0x2
    EvtQueryForwardDirection     = 0x100
    EvtQueryReverseDirection     = 0x200
    EvtQueryTolerateQueryErrors  = 0x1000

    ERROR_INSUFFICIENT_BUFFER    = 122

    ERROR_EVT_INVALID_QUERY      = 15001
    ERROR_EVT_CHANNEL_NOT_FOUND  = 15007

    EvtRenderEventValues  = 0
    EvtRenderEventXml     = 1
    EvtRenderBookmark     = 2

    def initialize
      super
      require 'Win32API'
    end

    config_param :channel, :string
    config_param :tag, :string
    config_param :pos_file, :string, :default => nil

    def configure(conf)
      super
      @event_handle = EvtQuery(0, @channel, 0, EvtQueryChannelPath | EvtQueryReverseDirection)
      if @event_handle == 0
        status = GetLastError()
        case status
        when ERROR_EVT_CHANNEL_NOT_FOUND
          raise ConfigError, "windows_event: The channel was not found."
        when ERROR_EVT_INVALID_QUERY
          raise ConfigError, "windows_event: The query is not valid."
        else
          raise ConfigError, sprintf("windows_event: EvtQuery failed with %d.", status)
        end
      end
    end

    def start
      @thread = Thread.new(&method(:run))
      $log.warn "hahaha"
    end

    def shutdown
      @running = false
      @thread.join
      if !@session_handle or @session_handle != 0
        EvtClose(@session_handle)
      end
    end

    def run
      @running = true
      while @running
        print_result(10)
        sleep(1)
      end
      @running = false
    end

    def print_event(event_handle)
      buffer_used = "\0" * 8
      property_count = "\0" * 8
      rendered_content = "\0"
      puts 'event_handle: ' + event_handle.to_s
      if EvtRender(0, event_handle, EvtRenderEventXml, 0, rendered_content, buffer_used, property_count) == 0
        status = GetLastError()
        if status == ERROR_INSUFFICIENT_BUFFER
          buffer_size = buffer_used.unpack('L')[0]
          puts 'buffer_size: ' + buffer_size.to_s
          rendered_content = "\0" * buffer_size
          rendered_content.force_encoding(Encoding::UTF_16LE)
          if EvtRender(0, event_handle, EvtRenderEventXml, buffer_size, rendered_content, buffer_used, property_count) == 0
            puts 'print_event error2: ' + GetLastError().to_s
          else
            puts 'sccess'
            return rendered_content.strip.encode(Encoding::UTF_8)
          end
        else
          $log.error "windows_event: print_event error: " + status.to_s
        end
      else
        return rendered_content.strip.encode(Encoding::UTF_8)
      end
    end

    def print_result(array_size)
      event_array = "\0" * 8 * array_size
      returned = "\0" * 8
      if EvtNext(@event_handle, array_size, event_array, 100, 0, returned) == 0
        $log.error "windows_event: print_result error: " + GetLastError().to_s
      else
        #puts 'EvtNext: Success'
        num = returned.unpack('L!')[0]
        case RUBY_PLATFORM
        when /x64|x86_64/
          events = event_array.unpack('Q*')
        else
          events = event_array.unpack('I*')
        end
        puts 'num: ' + num.to_s
        puts 'events.size: ' + events.size.to_s
        result = Array.new
        for i in 0..(num-1)
          result.push(print_event(events[i]))
        end
        es = MultiEventStream.new
        puts 'Create MultiEventStream'
        #Tracer.on
        result.each do |event|
          puts event.class
          puts event.encoding
          puts event
          begin
            doc = REXML::Document.new(event)
            #puts doc
            time = Time.iso8601(doc.elements['Event/System/TimeCreated'].attributes['SystemTime'])
            #puts time
            record = {
              '' => doc.,
            }
            es.add(time.to_i, Hash.from_xml(doc))
          rescue
            puts 'exception'
          end
        end
        unless es.empty?
          begin
            Engine.emit_stream(@tag, es)
          rescue
            # ignore errors. Engine shows logs and backtraces.
          end
        end
        Tracer.off
      end
    end

    # Original syntax
    # EVT_HANDLE WINAPI EvtQuery(
    #   _In_  EVT_HANDLE Session,
    #   _In_  LPCWSTR Path,
    #   _In_  LPCWSTR Query,
    #   _In_  DWORD Flags
    # );
    # See also: http://msdn.microsoft.com/en-us/library/windows/desktop/aa385466.aspx
    def EvtQuery(session, path, query, flags)
      return Win32API.new('Wevtapi', 'EvtQuery', %w(p p p l), 'l').call(session, path.encode(Encoding::UTF_16LE), query, flags)
    end

    # Original syntax
    # BOOL WINAPI EvtNext(
    #   _In_   EVT_HANDLE ResultSet,
    #   _In_   DWORD EventArraySize,
    #   _In_   EVT_HANDLE* EventArray,
    #   _In_   DWORD Timeout,
    #   _In_   DWORD Flags,
    #   _Out_  PDWORD Returned
    # );
    # See also: http://msdn.microsoft.com/en-us/library/windows/desktop/aa385405.aspx
    def EvtNext(result_set, event_array_size, event_array, timeout, flags, returned)
      return Win32API.new('Wevtapi', 'EvtNext', %w(l l p l l p), 'i').call(result_set, event_array_size, event_array, timeout, flags, returned)
    end

    # Original syntax
    # BOOL WINAPI EvtClose(
    #   _In_  EVT_HANDLE Object
    # );
    # See also: http://msdn.microsoft.com/en-us/library/windows/desktop/aa385344.aspx
    def EvtClose(session)
      return Win32API.new('Wevtapi', 'EvtClose', %w(l), 'i').call(session)
    end

    # Original syntax
    # BOOL WINAPI EvtRender(
    #   _In_   EVT_HANDLE Context,
    #   _In_   EVT_HANDLE Fragment,
    #   _In_   DWORD Flags,
    #   _In_   DWORD BufferSize,
    #   _In_   PVOID Buffer,
    #   _Out_  PDWORD BufferUsed,
    #   _Out_  PDWORD PropertyCount
    # );
    # See also: http://msdn.microsoft.com/en-us/library/windows/desktop/aa385471.aspx
    def EvtRender(context, fragment, flags, buffer_size, buffer, buffer_used, property_count)
      return Win32API.new('Wevtapi', 'EvtRender', %w(l l l l p p p), 'i').call(context, fragment, flags, buffer_size, buffer, buffer_used, property_count)
    end

    # Original syntax
    # DWORD WINAPI GetLastError(void);
    # See also: http://msdn.microsoft.com/en-us/library/windows/desktop/ms679360.aspx
    def GetLastError
      return Win32API.new('Kernel32', 'GetLastError', nil, 'l').call
    end
  end
end

class Hash
  class << self

    def from_xml(rexml)
      xml_elem_to_hash rexml.root
    end

    private

    def xml_elem_to_hash(elem)
      value = if elem.has_elements?
        children = {}
        elem.each_element do |e|
          children.merge!(xml_elem_to_hash(e)) do |k,v1,v2|
            v1.class == Array ?  v1 << v2 : [v1,v2]
          end
        end
        children
      else
        elem.text
      end
      { elem.name.to_sym => value }
    end

  end
end

