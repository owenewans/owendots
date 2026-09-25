set -gx EDITOR micro
set -gx VISUAL micro
if status is-interactive
    set -g fish_greeting
    set -g fish_color_normal '{{foreground}}'
    set -g fish_color_command '{{accent}}'
    set -g fish_color_error '{{red}}'
    set -g fish_color_param '{{foreground}}'
    set -g fish_color_comment '{{muted}}'
    starship init fish | source
end
