package PDL::Graphics::TriD::OOGL;

$PDL::Graphics::TriD::create_window_sub = sub {
   return new PDL::Graphics::TriD::OOGL::Window;
};

package PDL::Graphics::TriD::Object;

use OpenGL qw(:all);

use PDL::Graphics::OpenGL::Perl::OpenGL;
sub tooogl {
   my($this) = @_;
   join "\n",map { $_->togl() } (@{$this->{Objects}})
}

package PDL::Graphics::TriD::GL::Window;
use FileHandle;

sub new {my($type) = @_;
   my($this) = bless {},$type;
}

sub update_list {
   local $SIG{PIPE}= sub {}; # Prevent crashing if user exits the pager
   my($this) = @_;
   my $fh = new FileHandle("|togeomview");
   my $str = join "\n",map {$_->tooogl()} (@{$this->{Objects}}) ;
   print $str;
   $fh->print($str);
}

sub twiddle {
}

1;
