int f() {
  int c = 0;
  while (1) {
    if (c > 10)
      return c;
    c++;      
  }
  // return;
}

int main() {
  printf("%d\n", f());
}

