# frozen_string_literal: true

# Relogio falso e seguro para threads: dormir apenas avanca o tempo simulado.
class RelogioFalso
  def initialize(inicio = 0.0)
    @t = inicio
    @mutex = Mutex.new
    @sonos = []
  end

  def sonos = @mutex.synchronize { @sonos.dup }

  def agora = @mutex.synchronize { @t }

  def dormir(segundos)
    @mutex.synchronize do
      @sonos << segundos
      @t += segundos
    end
  end

  def relogio = -> { agora }
  def sono = ->(s) { dormir(s) }
end
